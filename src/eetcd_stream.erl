-module(eetcd_stream).

%% API
-export([unary/3]).
-export([new/1]).
-export([data/2, data/3, data/4]).

-define(TIMEOUT, 5000).
-define(HEADERS, [{<<"grpc-encoding">>, <<"identity">>}, {<<"content-type">>, <<"application/grpc+proto">>}]).

-spec new(Path) -> {ok, GunPid, Http2Ref} when
    Path :: iodata(),
    GunPid :: pid(),
    Http2Ref :: reference().
new(Path) ->
    Pid = eetcd_http2_keeper:get_http2_client_pid(),
    {ok, Pid, gun:request(Pid, <<"POST">>, Path, ?HEADERS)}.

-spec data(EtcdRequest, Http2Path) -> Http2Ref when
    EtcdRequest :: tuple(),
    Http2Path :: iodata(),
    Http2Ref :: reference().
data(Request, Path) ->
    {ok, Pid, Ref} = new(Path),
    data(Pid, Ref, Request, nofin),
    Ref.

-spec data(Http2Ref, EtcdRequest, Http2Path) -> ok when
    Http2Ref :: reference(),
    EtcdRequest :: tuple(),
    Http2Path :: iodata().
data(Ref, Request, IsFin) ->
    Pid = eetcd_http2_keeper:get_http2_client_pid(),
    data(Pid, Ref, Request, IsFin).

-spec data(GunPid, Http2Ref, EtcdRequest, Http2Path) -> Http2Ref when
    GunPid :: pid(),
    Http2Ref :: reference(),
    EtcdRequest :: tuple(),
    Http2Path :: iodata().
data(Pid, Ref, Request, IsFin) ->
    EncodeBody = eetcd_grpc:encode(identity, Request),
    gun:data(Pid, Ref, IsFin, EncodeBody),
    Ref.

-spec unary(EtcdRequest, Http2Path, EtcdResponseType) -> EtcdResponse when
    EtcdRequest :: tuple(),
    Http2Path :: iodata(),
    EtcdResponseType :: atom(),
    EtcdResponse :: tuple().
unary(Request, Path, ResponseType) ->
    EncodeBody = eetcd_grpc:encode(identity, Request),
    Pid = eetcd_http2_keeper:get_http2_client_pid(),
    StreamRef = gun:request(Pid, <<"POST">>, Path, ?HEADERS, EncodeBody),
    MRef = erlang:monitor(process, Pid),
    Res =
        case gun:await(Pid, StreamRef, ?TIMEOUT, MRef) of
            {response, nofin, 200, _Headers} ->
                case gun:await_body(Pid, StreamRef, ?TIMEOUT, MRef) of
                    {ok, ResBody, _Trailers} ->
                        {ok, eetcd_grpc:decode(identity, ResBody, ResponseType)};
                    {error, _} = Error1 ->
                        Error1
                end;
            {response, fin, 200, Headers} ->
                GrpcStatus = proplists:get_value(<<"grpc-status">>, Headers, <<"0">>),
                GrpcMessage = proplists:get_value(<<"grpc-message">>, Headers, <<"">>),
                {error, {'grpc_error', binary_to_integer(GrpcStatus), GrpcMessage}};
            {error, _} = Error2 ->
                Error2
        end,
    erlang:demonitor(MRef, [flush]),
    Res.
