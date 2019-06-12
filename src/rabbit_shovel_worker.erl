%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at https://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ.
%%
%%  The Initial Developer of the Original Code is GoPivotal, Inc.
%%  Copyright (c) 2007-2019 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_shovel_worker).
-behaviour(gen_server2).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% for testing purposes
-export([get_connection_name/1]).

-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_shovel.hrl").

-record(state, {inbound_conn, inbound_ch, outbound_conn, outbound_ch,
                name, type, config, inbound_uri, outbound_uri, unacked,
                remaining, %% [1]
                remaining_unacked}). %% [2]

%% [1] Counts down until we shut down in all modes
%% [2] Counts down until we stop publishing in on-confirm mode

start_link(Type, Name, Config) ->
    ok = rabbit_shovel_status:report(Name, Type, starting),
    gen_server2:start_link(?MODULE, [Type, Name, Config], []).

%%---------------------------
%% Gen Server Implementation
%%---------------------------

init([Type, Name, Config0]) ->
    Config = case Type of
                static ->
                     Config0;
                dynamic ->
                    ClusterName = rabbit_nodes:cluster_name(),
                    {ok, Conf} = rabbit_shovel_parameters:parse(Name,
                                                                ClusterName,
                                                                Config0),
                    Conf
            end,
    case Name of
      {VHost, ShovelName} -> rabbit_log:debug("Initialising a Shovel '~s' of type '~s' in virtual host '~s'", [ShovelName, Type, VHost]);
      ShovelName          -> rabbit_log:debug("Initialising a Shovel '~s' of type '~s'", [ShovelName, Type])
    end,
    gen_server2:cast(self(), init),
    {ok, #state{name = Name, type = Type, config = Config}}.

handle_call(_Msg, _From, State) ->
    {noreply, State}.

handle_cast(init, State = #state{config = Config0}) ->
    try rabbit_shovel_behaviour:connect_source(Config0) of
      Config ->
        case maps:get(name, Config) of
          {VHost, ShovelName} -> rabbit_log:debug("Shovel '~s' in virtual host '~s' connected to source", [ShovelName, VHost]);
          ShovelName          -> rabbit_log:debug("Shovel '~s' connected to source", [ShovelName])
        end,
        %% this makes sure that connection pid is updated in case
        %% any of the subsequent connection/init steps fail. See
        %% rabbitmq/rabbitmq-shovel#54 for context.
        gen_server2:cast(self(), connect_dest),
        {noreply, State#state{config = Config}}
    catch _:_ ->
      case maps:get(name, Config0) of
        {VHost, ShovelName} -> rabbit_log:error("Shovel '~s' in virtual host '~s' failed to connect to source", [ShovelName, VHost]);
        ShovelName          -> rabbit_log:error("Shovel '~s' failed to connect to source", [ShovelName])
      end,
      {stop, shutdown, State}
    end;
handle_cast(connect_dest, State = #state{config = Config0}) ->
    try rabbit_shovel_behaviour:connect_dest(Config0) of
      Config ->
        case maps:get(name, Config) of
          {VHost, ShovelName} -> rabbit_log:debug("Shovel '~s' in virtual host '~s' connected to destination", [ShovelName, VHost]);
          ShovelName          -> rabbit_log:debug("Shovel '~s' connected to destination", [ShovelName])
        end,
        gen_server2:cast(self(), init_shovel),
        {noreply, State#state{config = Config}}
    catch _:_ ->
      case maps:get(name, Config0) of
        {VHost, ShovelName} -> rabbit_log:error("Shovel '~s' in virtual host '~s' failed to connect to destination", [ShovelName, VHost]);
        ShovelName          -> rabbit_log:error("Shovel '~s' failed to connect to destination", [ShovelName])
      end,
      {stop, shutdown, State}
    end;
handle_cast(init_shovel, State = #state{config = Config}) ->
    %% Don't trap exits until we have established connections so that
    %% if we try to shut down while waiting for a connection to be
    %% established then we don't block
    process_flag(trap_exit, true),
    Config1 = rabbit_shovel_behaviour:init_dest(Config),
    Config2 = rabbit_shovel_behaviour:init_source(Config1),
    case maps:get(name, Config2) of
      {VHost, ShovelName} -> rabbit_log:debug("Shovel '~s' in virtual host '~s' has finished setting up its topology", [ShovelName, VHost]);
      ShovelName          -> rabbit_log:debug("Shovel '~s' has finished setting up its topology", [ShovelName])
    end,
    State1 = State#state{config = Config2},
    ok = report_running(State1),
    {noreply, State1}.


handle_info(Msg, State = #state{config = Config, name = Name}) ->
    case rabbit_shovel_behaviour:handle_source(Msg, Config) of
        not_handled ->
            case rabbit_shovel_behaviour:handle_dest(Msg, Config) of
                not_handled ->
                    case Name of
                      {VHost, ShovelName} -> rabbit_log:warning("Shovel '~s' in virtual host '~s' could not handle a destination message ~p", [ShovelName, VHost, Msg]);
                      ShovelName          -> rabbit_log:warning("Shovel '~s' could not handle a destination message ~p", [ShovelName, Msg])
                    end,
                    {noreply, State};
                {stop, {outbound_conn_died, Reason}} ->
                    case Name of
                      {VHost, ShovelName} -> rabbit_log:error("Shovel '~s' in virtual host '~s' detected destination connection failure", [ShovelName, VHost]);
                      ShovelName          -> rabbit_log:error("Shovel '~s' detected destination connection failure", [ShovelName])
                    end,
                    {stop, Reason, State};
                {stop, Reason} ->
                    case Name of
                      {VHost, ShovelName} -> rabbit_log:debug("Shovel '~s' in virtual host '~s' decided to stop due a message from destination: ~p", [ShovelName, VHost, Msg]);
                      ShovelName          -> rabbit_log:debug("Shovel '~s' decided to stop due a message from destination: ~p", [ShovelName, Msg])
                    end,
                    {stop, Reason, State};
                Config1 ->
                    {noreply, State#state{config = Config1}}
            end;
        {stop, {inbound_conn_died, Reason}} ->
            case Name of
              {VHost, ShovelName} -> rabbit_log:error("Shovel '~s' in virtual host '~s' detected source connection failure", [ShovelName, VHost, Msg]);
              ShovelName          -> rabbit_log:error("Shovel '~s' detected source connection failure: ~p", [ShovelName, Msg])
            end,
            {stop, Reason, State};
        {stop, Reason} ->
            case Name of
              {VHost, ShovelName} -> rabbit_log:debug("Shovel '~s' in virtual host '~s' decided to stop due a message from source: ~p", [ShovelName, VHost, Msg]);
              ShovelName          -> rabbit_log:debug("Shovel '~s' decided to stop due a message from source: ~p", [ShovelName, Msg])
            end,
            {stop, Reason, State};
        Config1 ->
            {noreply, State#state{config = Config1}}
    end.

terminate({shutdown, autodelete}, State = #state{name = {VHost, Name},
                                                 type = dynamic}) ->
    rabbit_log:info("Shovel '~s' in virtual host '~s' is stopping (it was configured to autodelete and transfer is completed)", [Name, VHost]),
    close_connections(State),
    %% See rabbit_shovel_dyn_worker_sup_sup:stop_child/1
    put(shovel_worker_autodelete, true),
    _ = rabbit_runtime_parameters:clear(VHost, <<"shovel">>, Name, ?SHOVEL_USER),
    rabbit_shovel_status:remove({VHost, Name}),
    ok;
terminate(shutdown, State) ->
    close_connections(State),
    ok;
terminate(shutdown, State) ->
    close_connections(State),
    ok;
terminate(socket_closed_unexpectedly, State) ->
    close_connections(State),
    ok;
terminate(socket_closed_unexpectedly, State) ->
    close_connections(State),
    ok;
terminate({'EXIT', outbound_conn_died}, State = #state{name = {VHost, Name}}) ->
    rabbit_log:error("Shovel '~s' in virtual host '~s' is stopping because destination connection failed", [Name, VHost]),
    rabbit_shovel_status:report(State#state.name, State#state.type,
                                {terminated, "destination connection failed"}),
    close_connections(State),
    ok;
terminate({'EXIT', outbound_conn_died}, State = #state{name = Name}) ->
    rabbit_log:error("Shovel '~s' is stopping because destination connection failed", [Name]),
    rabbit_shovel_status:report(State#state.name, State#state.type,
                                {terminated, "destination connection failed"}),
    close_connections(State),
    ok;
terminate({'EXIT', inbound_conn_died}, State = #state{name = {VHost, Name}}) ->
    rabbit_log:error("Shovel '~s' in virtual host '~s' is stopping because destination connection failed", [Name, VHost]),
    rabbit_shovel_status:report(State#state.name, State#state.type,
                                {terminated, "source connection failed"}),
    close_connections(State),
    ok;
terminate({'EXIT', inbound_conn_died}, State = #state{name = Name}) ->
    rabbit_log:error("Shovel '~s' is stopping because source connection failed", [Name]),
    rabbit_shovel_status:report(State#state.name, State#state.type,
                                {terminated, "destination connection failed"}),
    close_connections(State),
    ok;
terminate(Reason, State = #state{name = {VHost, Name}}) ->
    rabbit_log:error("Shovel '~s' in virtual host '~s' is stopping, reason: ~p", [Name, VHost, Reason]),
    rabbit_shovel_status:report(State#state.name, State#state.type,
                                {terminated, Reason}),
    close_connections(State),
    ok;
terminate(Reason, State = #state{name = Name}) ->
    rabbit_log:error("Shovel '~s' is stopping, reason: ~p", [Name, Reason]),
    rabbit_shovel_status:report(State#state.name, State#state.type,
                                {terminated, Reason}),
    close_connections(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%---------------------------
%% Helpers
%%---------------------------

report_running(#state{config = Config} = State) ->
    InUri = rabbit_shovel_behaviour:source_uri(Config),
    OutUri = rabbit_shovel_behaviour:dest_uri(Config),
    InProto = rabbit_shovel_behaviour:source_protocol(Config),
    OutProto = rabbit_shovel_behaviour:dest_protocol(Config),
    InEndpoint = rabbit_shovel_behaviour:source_endpoint(Config),
    OutEndpoint = rabbit_shovel_behaviour:dest_endpoint(Config),
    rabbit_shovel_status:report(State#state.name, State#state.type,
                                {running, [{src_uri,  rabbit_data_coercion:to_binary(InUri)},
                                           {src_protocol, rabbit_data_coercion:to_binary(InProto)},
                                           {dest_protocol, rabbit_data_coercion:to_binary(OutProto)},
                                           {dest_uri, rabbit_data_coercion:to_binary(OutUri)}]
                                 ++ props_to_binary(InEndpoint) ++ props_to_binary(OutEndpoint)
                                }).

props_to_binary(Props) ->
    [{K, rabbit_data_coercion:to_binary(V)} || {K, V} <- Props].

%% for static shovels, name is an atom from the configuration file
get_connection_name(ShovelName) when is_atom(ShovelName) ->
    Prefix = <<"Shovel ">>,
    ShovelNameAsBinary = atom_to_binary(ShovelName, utf8),
    <<Prefix/binary, ShovelNameAsBinary/binary>>;

%% for dynamic shovels, name is a tuple with a binary
get_connection_name({_, Name}) when is_binary(Name) ->
    Prefix = <<"Shovel ">>,
    <<Prefix/binary, Name/binary>>;

%% fallback
get_connection_name(_) ->
    <<"Shovel">>.

close_connections(#state{config = Conf}) ->
    ok = rabbit_shovel_behaviour:close_source(Conf),
    ok = rabbit_shovel_behaviour:close_dest(Conf).
