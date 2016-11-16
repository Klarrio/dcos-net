%%%-------------------------------------------------------------------
%%% @author Anatoly Yakovenko
%%% @copyright (C) 2016, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 24. Oct 2016 11:42 AM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_metrics).
-author("Anatoly Yakovenko").

-include_lib("telemetry/include/telemetry.hrl").
-include_lib("ip_vs_conn/include/ip_vs_conn.hrl").

-export([start_link/0]).

-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-type backend_conns() :: #{inet:ip4_address() => [#ip_vs_conn{}]}.

-record(state, {
          conns = maps:new() :: conn_map(),
          backend_conns = maps:new() :: backend_conns()
    }).

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(init(term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |

    {stop, Reason :: term()} | ignore).
init([]) ->
    process_flag(trap_exit, true),
    erlang:send_after(splay_ms(), self(), push_metrics),
    {ok, #state{}}.

-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
    {noreply, State}.

-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info(push_metrics, State = #state{}) ->
    {NewConns, NewBCs} = check_connections(State#state.conns, State#state.backend_conns),
    erlang:send_after(splay_ms(), self(), push_metrics),
    {noreply, State#state{conns = NewConns, backend_conns = NewBCs}};
handle_info(_Info, State) ->
    {noreply, State}.

-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State = #state{}) ->
    ok.

-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% TODO: borrowed from dcos_l4lb, should probably be a util somewhere
-spec(splay_ms() -> integer()).
splay_ms() ->
    MsPerMinute = dcos_l4lb_config:metrics_interval_seconds() * 1000,
    NextMinute = -1 * erlang:monotonic_time(milli_seconds) rem MsPerMinute,
    SplayMS = dcos_l4lb_config:metrics_splay_seconds() * 1000,
    FlooredSplayMS = max(1, SplayMS),
    Splay = rand:uniform(FlooredSplayMS),
    NextMinute + Splay.

%% implementation
-spec(check_connections(conn_map(), backend_conns()) -> {conn_map(), backend_conns()}).
check_connections(OldConns, OldParsedMap) ->
    {ok, Conns} = ip_vs_conn_monitor:get_connections(),
    Splay = dcos_l4lb_config:metrics_splay_seconds(),
    Interval = dcos_l4lb_config:metrics_interval_seconds(),
    PollDelay = 2*(Splay + Interval), %% assuming these delays are the same in ip_vs_conn
    OnlyNewConns = new_connections(OldConns, Conns),
    Parsed = lists:map(fun ip_vs_conn:parse/1, maps:to_list(OnlyNewConns)),
    lists:foreach(fun (C) -> apply_connection(C, PollDelay) end, Parsed),
    ParsedMap = lists:foldl(fun vip_addr_map/2, #{}, Parsed),
    {ok, Metrics} = tcp_metrics_monitor:get_metrics(),
    process_p99s(Metrics, OldParsedMap, ParsedMap),
    {Conns, ParsedMap}.

process_p99s(Metrics, OldParsedMap, ParsedMap) ->
    P99s = get_p99s(ParsedMap, Metrics),
    New = lists:flatmap(fun apply_p99/1, P99s),
    OldP99s = get_p99s(OldParsedMap, Metrics),
    Old = lists:flatmap(fun apply_p99/1, OldP99s),
    Old ++ New.

vip_addr_map(C = #ip_vs_conn{dst_ip = IP}, Z) ->
    vip_addr_map(C, Z, maps:get(int_to_ip(IP), Z, undefined)).

vip_addr_map(C = #ip_vs_conn{dst_ip = IP}, Z, undefined) ->
    maps:put(int_to_ip(IP), [C], Z);
vip_addr_map(C = #ip_vs_conn{dst_ip = IP}, Z, Ls) ->
    maps:put(int_to_ip(IP), [C | Ls], Z).

new_connections(OldConns, AllConns) ->
    maps:filter(fun(K, V) -> has_new_state(OldConns, {K, V}) end, AllConns).

has_new_state(_OldConns, {_K, #ip_vs_conn_status{tcp_state = syn_recv}}) -> true;
has_new_state(_OldConns, {_K, #ip_vs_conn_status{tcp_state = syn_sent}}) -> true;
has_new_state(OldConns, {K, _V}) -> not(maps:is_key(K, OldConns)).

-spec(apply_connection(#ip_vs_conn{}, integer()) -> ok).
apply_connection(Conn = #ip_vs_conn{expires = Expires, tcp_state = syn_recv},
                  PollDelay) when Expires < PollDelay ->
    conn_failed(Conn);
apply_connection(Conn = #ip_vs_conn{expires = Expires, tcp_state = syn_sent},
                  PollDelay) when Expires < PollDelay ->
    conn_failed(Conn);
apply_connection(#ip_vs_conn{tcp_state = syn_recv}, _PollDelay) -> ok;
apply_connection(#ip_vs_conn{tcp_state = syn_sent}, _PollDelay) -> ok;
apply_connection(Conn, _PollDelay) ->
    conn_success(Conn).

-spec(conn_failed(#ip_vs_conn{}) -> ok).
conn_failed(#ip_vs_conn{dst_ip = IP, dst_port = Port,
                        to_ip = VIP, to_port = VIPPort}) ->
    Tags = named_tags(IP, Port, VIP, VIPPort),
    AggTags = [[hostname], [hostname, backend]],
    telemetry:counter(mm_connect_failures, Tags, AggTags, 1).

-spec(conn_success(#ip_vs_conn{}) -> ok).
conn_success(#ip_vs_conn{dst_ip = IP, dst_port = Port,
                         to_ip = VIP, to_port = VIPPort}) ->
    Tags = named_tags(IP, Port, VIP, VIPPort),
    AggTags = [[hostname], [hostname, backend]],
    telemetry:counter(mm_connect_successes, Tags, AggTags, 1).

get_p99s(Conns, Metrics) ->
    lists:flatmap(fun (M) -> get_p99_updates(Conns, M) end, Metrics).

get_p99_updates(Conns, {netlink, tcp_metrics, _, _, _, {get, _, _, Attrs}}) ->
    match_metrics(Conns, proplists:get_value(d_addr, Attrs), proplists:get_value(vals, Attrs)).

match_metrics(_, undefined, _) -> [];
match_metrics(_, _, undefined) -> [];
match_metrics(Conns, Addr, Vals) -> match_conn(maps:get(Addr, Conns, undefined),
                                               proplists:get_value(rtt_us, Vals),
                                               proplists:get_value(rtt_var_us, Vals)).
match_conn(undefined, _, _) -> [];
match_conn(_, undefined, _) -> [];
match_conn(_, _, undefined) -> [];
match_conn(Conns, RttUs, RttVarUs) -> [{Conns, RttUs, RttVarUs}].

apply_p99({Conns, RttUs, RttVarUs}) ->
    lists:flatmap(fun(C) -> apply_p99(C, RttUs, RttVarUs) end, Conns).

apply_p99(C = #ip_vs_conn{dst_ip = IP, dst_port = Port,
                          to_ip = VIP, to_port = VIPPort},
          RttUs, RttVarUs) ->
    P99 = erlang:round(1000*(RttUs + math:sqrt(RttVarUs)*3)),
    Tags = named_tags(IP, Port, VIP, VIPPort),
    AggTags = [[hostname], [hostname, backend]],
    telemetry:histogram(mm_connect_latency, Tags, AggTags, P99),
    [{C, RttUs, RttVarUs}].


-spec(named_tags(IIP :: integer(),
                 Port :: inet:port_numbrer(),
                 IVIP :: integer(),
                 VIPPort :: inet:port_numbrer()) -> map:map()).
named_tags(IIP, Port, IVIP, VIPPort) ->
    IP = int_to_ip(IIP),
    VIP = int_to_ip(IVIP),
    case dcos_l4lb_lashup_vip_listener:lookup_vips([{ip, VIP}]) of
        [{name, VIPName}] -> #{vip => fmt_ip_port(VIP, VIPPort), backend => fmt_ip_port(IP, Port), name => VIPName};
        _ -> #{vip => fmt_ip_port(VIP, VIPPort), backend => fmt_ip_port(IP, Port)}
    end.

int_to_ip(Int) -> dcos_l4lb_lashup_vip_listener:integer_to_ip(Int).

-spec(fmt_ip_port(IP :: inet:ip4_address(), Port :: inet:port_number()) -> binary()).
fmt_ip_port(IP, Port) ->
    IPString = inet_parse:ntoa(IP),
    List = io_lib:format("~s_~p", [IPString, Port]),
    list_to_binary(List).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

new_conn_test_() ->
    Conn = <<"foobar">>,
    ConnStatus = #ip_vs_conn_status{conn_state = <<"conn_state">>, tcp_state = established},
    New = new_connections(#{}, #{Conn => ConnStatus}),
    New1 = new_connections(#{Conn => ConnStatus}, #{Conn => ConnStatus}),
    [?_assertEqual(#{Conn => ConnStatus}, New),
     ?_assertEqual(#{}, New1)].

new_conn1_test_() ->
    Conn = <<"foobar">>,
    ConnStatus0 = #ip_vs_conn_status{conn_state = <<"0">>, tcp_state = syn_recv},
    ConnStatus1 = #ip_vs_conn_status{conn_state = <<"1">>, tcp_state = syn_recv},
    New = new_connections(#{Conn => ConnStatus0}, #{Conn => ConnStatus1}),
    [?_assertEqual(#{Conn => ConnStatus1}, New)].

get_p99s_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_us, 47313},
                    {rtt_ms, 47},
                    {rtt_var_us, 23656},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    DAddr = int_to_ip(IP),
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([{[Conn], 47313, 23656}], get_p99s(ConnMap, Metrics)),
     ?_assertEqual([{[Conn, Conn2], 47313, 23656}], get_p99s(ConnMap2, Metrics))].

process_p99s_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_us, 47313},
                    {rtt_ms, 47},
                    {rtt_var_us, 23656},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([{Conn, 47313, 23656}], process_p99s(Metrics, ConnMap, #{})),
     ?_assertEqual([{Conn, 47313, 23656}], process_p99s(Metrics, #{}, ConnMap)),
     ?_assertEqual([{Conn, 47313, 23656}, {Conn2, 47313, 23656}], process_p99s(Metrics, ConnMap2, #{})),
     ?_assertEqual([{Conn, 47313, 23656}, {Conn2, 47313, 23656}], process_p99s(Metrics, #{}, ConnMap2)),
     ?_assertEqual([{Conn, 47313, 23656}, {Conn, 47313, 23656}, {Conn2, 47313, 23656}], process_p99s(Metrics, ConnMap, ConnMap2)),
     ?_assertEqual([], process_p99s(Metrics, #{}, #{}))
    ].

process_p99s_1_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_us, 47313},
                    {rtt_ms, 47},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([], process_p99s(Metrics, ConnMap, ConnMap2))
    ].

process_p99s_2_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_var_us, 23656},
                    {rtt_ms, 47},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([], process_p99s(Metrics, ConnMap, ConnMap2))
    ].

process_p99s_3_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_var_us, 23656},
                    {rtt_ms, 47},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([], process_p99s(Metrics, ConnMap, ConnMap2))
    ].

process_p99s_4_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([], process_p99s(Metrics, ConnMap, ConnMap2))
    ].

-endif.
