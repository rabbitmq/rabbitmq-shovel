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
%%  Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module('Elixir.RabbitMQ.CLI.Ctl.Commands.RestartShovelCommand').

-include("rabbit_shovel.hrl").

-behaviour('Elixir.RabbitMQ.CLI.CommandBehaviour').

-export([
         usage/0,
         usage_additional/0,
         usage_doc_guides/0,
         flags/0,
         validate/2,
         merge_defaults/2,
         banner/2,
         run/2,
         aliases/0,
         output/2,
         help_section/0,
         description/0
        ]).


%%----------------------------------------------------------------------------
%% Callbacks
%%----------------------------------------------------------------------------

flags() ->
    [].

aliases() ->
    [].

validate([], _Opts) ->
    {validation_failure, not_enough_args};
validate([_], _Opts) ->
    ok;
validate(_, _Opts) ->
    {validation_failure, too_many_args}.

merge_defaults(A, O) ->
    {A, O}.

banner([Name], #{node := Node, vhost := VHost}) ->
    erlang:iolist_to_binary([<<"Restarting dynamic Shovel ">>, Name, <<" in virtual host ">>, VHost,
                             << " on node ">>, atom_to_binary(Node, utf8)]).

run([Name], #{node := Node, vhost := VHost}) ->
    case rabbit_misc:rpc_call(Node, rabbit_shovel_status, lookup, [{VHost, Name}]) of
        {badrpc, _} = Error ->
            Error;
        not_found ->
            {error, <<"Shovel with the given name was not found in the target virtual host">>};
        _Obj ->
            ok = rabbit_misc:rpc_call(Node, rabbit_shovel_dyn_worker_sup_sup, stop_child,
                                      [{VHost, Name}]),
            {ok, _} = rabbit_misc:rpc_call(Node, rabbit_shovel_dyn_worker_sup_sup, start_link,
                                           []),
            ok
    end.

output(Output, _Opts) ->
    'Elixir.RabbitMQ.CLI.DefaultOutput':output(Output).

usage() ->
     <<"restart_shovel <name>">>.

usage_additional() ->
   [
      {<<"<name>">>, <<"name of the Shovel to restart">>}
   ].

usage_doc_guides() ->
    [?SHOVEL_GUIDE_URL].

help_section() ->
   {plugin, shovel}.

description() ->
   <<"Restarts a dynamic Shovel">>.
