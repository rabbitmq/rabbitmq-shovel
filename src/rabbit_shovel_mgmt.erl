%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ.
%%
%%  The Initial Developer of the Original Code is VMware, Inc.
%%  Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_shovel_mgmt).

-export([maybe_register/0]).
-export([dispatcher/0]).
-export([init/1, to_json/2, content_types_provided/2, is_authorized/2]).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("webmachine/include/webmachine.hrl").

maybe_register() ->
    case application:get_env(rabbitmq_management, plugins) of
        {ok, Curr} ->
            application:set_env(rabbitmq_management, plugins,
                                ordsets:add_element(?MODULE, Curr)),
            rabbit_mgmt_dispatcher:refresh(),
            ok;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------

dispatcher() ->
    [{["shovel-status"], ?MODULE, []}].

%%--------------------------------------------------------------------

%% TODO this is rather dubious
-record(context, {user, password}).

init(_Config) -> {ok, #context{}}.

content_types_provided(ReqData, Context) ->
   {[{"application/json", to_json}], ReqData, Context}.

to_json(ReqData, Context) ->
    rabbit_mgmt_util:reply(
      [format(I) || I <- rabbit_shovel_status:status()], ReqData, Context).

is_authorized(ReqData, Context) ->
    rabbit_mgmt_util:is_authorized_admin(ReqData, Context).

%%--------------------------------------------------------------------

format({Name, Info, TS}) ->
    [{name, Name}, {timestamp, format_ts(TS)} | format_info(Info)].

format_info(starting) ->
    [{state, starting}];

format_info({State, {source, Source}, {destination, Destination}}) ->
    [{state,       State},
     {source,      format_params(Source)},
     {destination, format_params(Destination)}];

format_info({terminated, Reason}) ->
    [{state,  terminated},
     {reason, print("~p", [Reason])}].

format_ts({{Y, M, D}, {H, Min, S}}) ->
    print("~w-~w-~w ~w:~w:~w", [Y, M, D, H, Min, S]).

format_params(Params) ->
    rabbit_mgmt_format:record(Params#amqp_params{password        = undefined,
                                                 auth_mechanisms = undefined},
                              record_info(fields, amqp_params)).

print(Fmt, Val) ->
    list_to_binary(io_lib:format(Fmt, Val)).
