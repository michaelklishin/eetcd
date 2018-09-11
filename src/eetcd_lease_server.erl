-module(eetcd_lease_server).

-behaviour(gen_server).

%% API
-export([keep_alive/1]).
-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("eetcd.hrl").

-record(state, {pid, stream_ref, monitor_ref}).

%%====================================================================
%% API
%%====================================================================

-spec keep_alive(router_pb:'Etcd.LeaseKeepAliveRequest'()) -> ok.
keep_alive(Request) ->
    gen_server:call(?MODULE, {keep_alive, Request}).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, Pid, Ref} = eetcd_stream:new(<<"/etcdserverpb.Lease/LeaseKeepAlive">>),
    MonitorRef = erlang:monitor(process, Pid),
    erlang:process_flag(trap_exit, true),
    {ok, #state{pid = Pid, stream_ref = Ref, monitor_ref = MonitorRef}}.

handle_call({keep_alive, Request}, _From, State = #state{pid = Pid, stream_ref = Ref}) ->
    eetcd_stream:data(Pid, Ref, Request, nofin),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, Reason}, #state{pid = Pid, monitor_ref = Ref}) ->
    error_logger:warning_msg("gun(~p) process stop ~p~n", [Pid, Reason]),
    case reconnect(16, "") of
        {ok, State} -> {noreply, State};
        {error, Reason} -> {stop, Reason, #state{}}
    end;

handle_info({gun_response, _Pid, Ref, nofin, 200, _Headers}, State = #state{stream_ref = Ref}) ->
    {noreply, State};

handle_info({gun_data, _Pid, Ref, nofin, Data}, State = #state{stream_ref = Ref}) ->
    handle_change_event(State, Data);

handle_info({update_ttl, Id}, State = #state{stream_ref = Ref, pid = Pid}) ->
    Request = #'Etcd.LeaseKeepAliveRequest'{'ID' = Id},
    eetcd_stream:data(Pid, Ref, Request, nofin),
    {noreply, State};

handle_info(Info, State) ->
    error_logger:warning_msg("Leaser({~p,~p}) receive unknow msg ~p~n state~p~n",
        [?MODULE, self(), Info, State]),
    {noreply, State}.

terminate(_Reason, #state{stream_ref = Ref, pid = Pid}) ->
    gun:cancel(Pid, Ref),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_change_event(State, Data) ->
    T = #'Etcd.LeaseKeepAliveResponse'{'ID' = Id, 'TTL' = TTL}
        = eetcd_grpc:decode(identity, Data, 'Etcd.LeaseKeepAliveResponse'),
    io:format("lease ~p~n", [T]),
    case TTL > 0 of
        true -> erlang:send_after(round(TTL / 2) * 1000, self(), {update_ttl, Id});
        false -> stop
    end,
    {noreply, State}.

reconnect(0, Reason) -> {error, Reason};
reconnect(N, _OldReason) ->
    wait_http2_client_up(),
    case init([]) of
        {ok, State} -> {ok, State};
        {error, Reason} -> reconnect(N - 1, Reason)
    end.

wait_http2_client_up() ->
    case eetcd_http2_keeper:get_http2_client_pid() of
        undefined ->
            timer:sleep(200),
            wait_http2_client_up();
        _ -> ok
    end.
