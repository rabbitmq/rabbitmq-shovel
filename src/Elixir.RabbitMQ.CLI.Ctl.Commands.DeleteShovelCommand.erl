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
%%  Copyright (c) 2007-2020 Pivotal Software, Inc.  All rights reserved.
%%

-module('Elixir.RabbitMQ.CLI.Ctl.Commands.DeleteShovelCommand').

-include("rabbit_shovel.hrl").

-behaviour('Elixir.RabbitMQ.CLI.CommandBehaviour').

-export([
         usage/0,
         usage_additional/0,
         usage_doc_guides/0,
         validate/2,
         merge_defaults/2,
         banner/2,
         run/2,
         switches/0,
         aliases/0,
         output/2,
         help_section/0,
         description/0
        ]).


%%----------------------------------------------------------------------------
%% Callbacks
%%----------------------------------------------------------------------------
usage() ->
    <<"delete_shovel [--vhost <vhost>] <name>">>.

usage_additional() ->
    [
      {<<"<name>">>, <<"Shovel to delete">>}
    ].

usage_doc_guides() ->
    [?SHOVEL_GUIDE_URL].

description() ->
    <<"Deletes a Shovel">>.

help_section() ->
    {plugin, shovel}.

validate([], _Opts) ->
    {validation_failure, not_enough_args};
validate([_, _ | _], _Opts) ->
    {validation_failure, too_many_args};
validate([_], _Opts) ->
    ok.

merge_defaults(A, Opts) ->
    {A, maps:merge(#{vhost => <<"/">>}, Opts)}.

banner([Name], #{vhost := VHost}) ->
    erlang:list_to_binary(io_lib:format("Deleting shovel ~s in vhost ~s",
                                        [Name, VHost])).

run([Name], #{node := Node, vhost := VHost}) ->
    ActingUser = 'Elixir.RabbitMQ.CLI.Core.Helpers':cli_acting_user(),
    case rabbit_misc:rpc_call(Node, rabbit_shovel_util, delete_shovel, [VHost, Name, ActingUser]) of
        {badrpc, _} = Error ->
            Error;
        {error, not_found} ->
            ErrMsg = rabbit_misc:format("Shovel with the given name was not found "
                                        "on the target node '~s' and / or virtual host '~s'",
                                        [Node, VHost]),
            {error, rabbit_data_coercion:to_binary(ErrMsg)};
        ok -> ok
    end.

switches() ->
    [].

aliases() ->
    [].

output(E, _Opts) ->
    'Elixir.RabbitMQ.CLI.DefaultOutput':output(E).
