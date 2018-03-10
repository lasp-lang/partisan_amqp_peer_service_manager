%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Christopher S. Meiklejohn.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(partisan_amqp_peer_service_manager).
-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_server).
-behaviour(partisan_peer_service_manager).

-define(SET, state_awset).
-define(BROADCAST, <<"broadcast">>).

%% partisan_peer_service_manager callbacks
-export([start_link/0,
         members/0,
         myself/0,
         get_local_state/0,
         join/1,
         sync_join/1,
         leave/0,
         leave/1,
         on_up/2,
         on_down/2,
         update_members/1,
         send_message/2,
         cast_message/3,
         forward_message/3,
         cast_message/5,
         forward_message/5,
         cast_message/4,
         forward_message/4,
         receive_message/1,
         decode/1,
         reserve/1,
         partitions/0,
         inject_partition/2,
         resolve_partition/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("partisan/include/partisan.hrl").

-include_lib("amqp_client/include/amqp_client.hrl").

-record(state, {channel,
                connection,
                membership,
                myself :: node_spec()}).

-type state_t() :: #state{}.

%%%===================================================================
%%% partisan_peer_service_manager callbacks
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Return membership list.
members() ->
    gen_server:call(?MODULE, members, infinity).

%% @doc Return myself.
myself() ->
    partisan_peer_service_manager:myself().

%% @doc Return local node's view of cluster membership.
get_local_state() ->
    gen_server:call(?MODULE, get_local_state, infinity).

%% @doc Register a trigger to fire when a connection drops.
on_down(_Name, _Function) ->
    {error, not_implemented}.

%% @doc Register a trigger to fire when a connection opens.
on_up(_Name, _Function) ->
    {error, not_implemented}.

%% @doc Update membership.
update_members(_Nodes) ->
    {error, not_implemented}.

%% @doc Send message to a remote manager.
send_message(Name, Message) ->
    gen_server:call(?MODULE, {send_message, Name, Message}, infinity).

%% @doc Cast a message to a remote gen_server.
cast_message(Name, ServerRef, Message) ->
    cast_message(Name, ?DEFAULT_CHANNEL, ServerRef, Message).

%% @doc Cast a message to a remote gen_server.
cast_message(Name, Channel, ServerRef, Message) ->
    cast_message(Name, Channel, ServerRef, Message, []).

%% @doc Cast a message to a remote gen_server.
cast_message(Name, Channel, ServerRef, Message, _Options) ->
    FullMessage = {'$gen_cast', Message},
    forward_message(Name, Channel, ServerRef, FullMessage),
    ok.

%% @doc Forward message to registered process on the remote side.
forward_message(Name, ServerRef, Message) ->
    forward_message(Name, ?DEFAULT_CHANNEL, ServerRef, Message).

%% @doc Forward message to registered process on the remote side.
forward_message(Name, Channel, ServerRef, Message) ->
    forward_message(Name, Channel, ServerRef, Message, []).

%% @doc Forward message to registered process on the remote side.
forward_message(Name, _Channel, ServerRef, Message, _Options) ->
    gen_server:call(?MODULE, {forward_message, Name, ServerRef, Message}, infinity).

%% @doc Receive message from a remote manager.
receive_message(Message) ->
    gen_server:call(?MODULE, {receive_message, Message}, infinity).

%% @doc Attempt to join a remote node.
join(Node) ->
    gen_server:call(?MODULE, {join, Node}, infinity).

%% @doc Attempt to join a remote node.
sync_join(_Node) ->
    {error, not_implemented}.

%% @doc Leave the cluster.
leave() ->
    gen_server:call(?MODULE, {leave, node()}, infinity).

%% @doc Remove another node from the cluster.
leave(Node) ->
    gen_server:call(?MODULE, {leave, Node}, infinity).

%% @doc Decode state.
decode(State) ->
    sets:to_list(State).

%% @doc Reserve a slot for the particular tag.
reserve(_Tag) ->
    {error, no_available_slots}.

%% @doc Inject a partition.
inject_partition(_Origin, _TTL) ->
    {error, not_implemented}.

%% @doc Resolve a partition.
resolve_partition(_Reference) ->
    {error, not_implemented}.

%% @doc Return partitions.
partitions() ->
    {error, not_implemented}.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init([]) -> {ok, state_t()}.
init([]) ->
    %% Seed the process at initialization.
    rand:seed(exsplus, {erlang:phash2([node()]),
                        erlang:monotonic_time(),
                        erlang:unique_integer()}),

    %% Process connection exits.
    process_flag(trap_exit, true),

    %% Initialize membership.
    Myself = myself(),
    {ok, Membership} = ?SET:mutate({add, Myself}, Myself, ?SET:new()),

    %% Schedule periodic broadcast.
    schedule_broadcast(),

    case connect() of
        {ok, {Connection, Channel}} ->
            {ok, #state{myself=Myself, membership=Membership,
                        channel=Channel, connection=Connection}};
        {error, Reason} ->
            lager:error("Failure trying to open channel: ~p", [Reason]),
            {stop, Reason}
    end.

%% @private
-spec handle_call(term(), {pid(), term()}, state_t()) ->
    {reply, term(), state_t()}.

handle_call({leave, _Node}, _From, State) ->
    {reply, ok, State};

handle_call({join, #{name := _Name}=_Node}, _From, State) ->
    {reply, ok, State};

handle_call({send_message, Name, Message}, _From, #state{channel=Channel}=State0) ->
    {ok, State} = do_send_message(State0, Name, Message, Channel),
    {reply, ok, State};

handle_call({forward_message, Name, ServerRef, Message}, _From, #state{channel=Channel}=State0) ->
    {ok, State} = do_send_message(State0, 
                                  Name,
                                  {forward_message, ServerRef, Message},
                                  Channel),
    {reply, ok, State};

handle_call({receive_message, Message}, _From, State) ->
    handle_message(Message, State),
    {reply, ok, State};

handle_call(members, _From, #state{membership=Membership}=State) ->
    Members = [P || #{name := P} <- members(Membership)],
    {reply, {ok, Members}, State};

handle_call(get_local_state, _From, #state{membership=Membership}=State) ->
    {reply, {ok, Membership}, State};

handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call messages: ~p", [Msg]),
    {reply, ok, State}.

-spec handle_cast(term(), state_t()) -> {noreply, state_t()}.
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast messages: ~p", [Msg]),
    {noreply, State}.

handle_info(broadcast, #state{channel=Channel, membership=Membership0}=State0) ->
    Membership = ?SET:query(Membership0),

    %% Open direct exchanges and default channels.
    lists:foreach(fun(Node) ->
        gen_unicast_exchanges_channels_bindings(Node, Channel)
    end, sets:to_list(Membership)),

    %% Broadcast membership.
    {ok, State} = do_send_message(State0, {membership, Membership0}, Channel),

    schedule_broadcast(),

    {noreply, State};

handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

handle_info(#'basic.cancel_ok'{}, State) ->
    {noreply, State};

handle_info({#'basic.deliver'{delivery_tag = Tag}, #amqp_msg{payload=Payload}}, #state{channel=Channel}=State0) ->
    Decoded = binary_to_term(Payload),

    %% lager:info("Received: ~p", [Decoded]),

    %% Process message.
    State = handle_message(Decoded, State0),

    %% Ack.
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag}),

    {noreply, State};

handle_info(Msg, State) ->
    lager:warning("Unhandled info messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), state_t()) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, state_t(), term()) -> {ok, state_t()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
schedule_broadcast() ->
    BroadcastInterval = partisan_config:get(broadcast_interval, 1000),
    erlang:send_after(BroadcastInterval, ?MODULE, broadcast).

%% @private
gen_unicast_name(Node) when is_atom(Node) ->
    gen_unicast_name(#{name => Node});
gen_unicast_name(#{name := Name}) ->
    list_to_binary(atom_to_list(Name)).

%% @private
do_send_message(State, Message, Channel) ->
    BroadcastName = ?BROADCAST,
    Payload = term_to_binary(Message),
    Publish = #'basic.publish'{exchange = BroadcastName},
    do_rabbit_send(State, Channel, Publish, Payload).

%% @private
do_send_message(State, Name, Message, Channel) ->
    UnicastName = gen_unicast_name(Name),
    Payload = term_to_binary(Message),
    Publish = #'basic.publish'{exchange = UnicastName, routing_key = UnicastName},
    do_rabbit_send(State, Channel, Publish, Payload).

%% @private
gen_broadcast_exchanges_channels_bindings(Node, Channel) ->
    BroadcastName = ?BROADCAST,

    %% Generate a fanout exchange.
    ExchangeDeclare = #'exchange.declare'{exchange = BroadcastName, type = <<"fanout">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Channel, ExchangeDeclare),

    %% Generate a queue for our messages to be used by fanout exchange.
    UnicastName = gen_unicast_name(Node),
    QueueDeclare = #'queue.declare'{queue = UnicastName},
    #'queue.declare_ok'{} = amqp_channel:call(Channel, QueueDeclare),

    %% Bind our queue to fanout exchange.
    Binding = #'queue.bind'{queue = UnicastName,
                            exchange = BroadcastName,
                            routing_key = BroadcastName},
    #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),

    ok.

%% @private
gen_unicast_exchanges_channels_bindings(Node, Channel) ->
    UnicastName = gen_unicast_name(Node),

    %% Create a direct exchange for this node.
    ExchangeDeclare = #'exchange.declare'{exchange = UnicastName},
    #'exchange.declare_ok'{} = amqp_channel:call(Channel, ExchangeDeclare),

    %% Create a queue for this node.
    QueueDeclare = #'queue.declare'{queue = UnicastName},
    #'queue.declare_ok'{} = amqp_channel:call(Channel, QueueDeclare),

    %% Bind this queue to the direct exchange for this node;
    %% this serves as our unicast messaging channel for the node.
    Binding = #'queue.bind'{queue = UnicastName,
                            exchange = UnicastName,
                            routing_key = UnicastName},
    #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),

    ok.

%% @private
gen_broadcast_subscription(Node, Channel) ->
    UnicastName = gen_unicast_name(Node),

    %% Subscribe to our queue served by fanout exchange.
    Sub = #'basic.consume'{queue = UnicastName},
    #'basic.consume_ok'{consumer_tag = _Tag} = amqp_channel:call(Channel, Sub),

    ok.

%% @private
gen_unicast_subscription(Node, Channel) ->
    UnicastName = gen_unicast_name(Node),

    %% Subscribe to our queue / direct exchange for messages.
    Sub = #'basic.consume'{queue = UnicastName},
    #'basic.consume_ok'{consumer_tag = _Tag} = amqp_channel:call(Channel, Sub),

    ok.

%% @private
handle_message({membership, IncomingMembership}, #state{membership=Membership0}=State) ->
    Membership = ?SET:merge(IncomingMembership, Membership0),
    State#state{membership=Membership};
handle_message({forward_message, ServerRef, Message}, State) ->
    ServerRef ! Message,
    State.

%% @private
members(Membership) ->
    Members = ?SET:query(Membership),
    sets:to_list(Members).

%% @private
connect() ->
    Myself = myself(),

    ConnectionRecord = case application:get_env(partisan, amqp_uri, false) of
        false ->
            #amqp_params_network{};
        URI ->
            {ok, ParsedURI} = amqp_uri:parse(URI),
            ParsedURI
    end,

    case amqp_connection:start(ConnectionRecord) of
        {ok, Connection} ->
            case amqp_connection:open_channel(Connection) of
                {ok, Channel} ->
                    ok = gen_unicast_exchanges_channels_bindings(Myself, Channel),
                    ok = gen_broadcast_exchanges_channels_bindings(Myself, Channel),

                    ok = gen_unicast_subscription(Myself, Channel),
                    ok = gen_broadcast_subscription(Myself, Channel),

                    {ok, {Connection, Channel}};
                {error, Reason} ->
                    lager:error("Failure trying to open channels: ~p", [Reason]),
                    {error, Reason}
            end;
        {error, Reason} ->
            lager:error("Failure trying to open connection to URI ~p: ~p", 
                        [ConnectionRecord, Reason]),
            {error, Reason}
    end.

%% @private
do_rabbit_send(State, Channel, Publish, Payload) ->
    case amqp_channel:call(Channel, Publish, #amqp_msg{payload = Payload}) of
        closing ->
            lager:error("Connection was closing, attempting to reopen."),

            case connect() of
                {ok, {AMQPConnection, AMQPChannel}} ->
                    {ok, State#state{connection=AMQPConnection, channel=AMQPChannel}};
                {error, _Reason} ->
                    %% Try connection again at the next connection interval.
                    {ok, State}
            end;
        ok ->
            {ok, State};
        Other ->
            lager:info("AMQP reported ~p on send!", [Other]),
            {ok, State}
    end.