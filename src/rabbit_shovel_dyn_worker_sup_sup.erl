%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_shovel_dyn_worker_sup_sup).
-behaviour(mirrored_supervisor).

-export([start_link/0, init/1, adjust/2, stop_child/1]).

-import(rabbit_misc, [pget/2]).

-include("rabbit_shovel.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-define(SUPERVISOR, ?MODULE).

start_link() ->
    Pid = case mirrored_supervisor:start_link(
                  {local, ?SUPERVISOR}, ?SUPERVISOR,
                  fun rabbit_misc:execute_mnesia_transaction/1, ?MODULE, []) of
            {ok, Pid0}                       -> Pid0;
            {error, {already_started, Pid0}} -> Pid0
          end,
    Shovels = rabbit_runtime_parameters:list_component(<<"shovel">>),
    [start_child({pget(vhost, Shovel), pget(name, Shovel)},
                 pget(value, Shovel)) || Shovel <- Shovels],
    {ok, Pid}.

adjust(Name, Def) ->
    case child_exists(Name) of
        true  -> stop_child(Name);
        false -> ok
    end,
    start_child(Name, Def).

start_child(Name, Def) ->
    case mirrored_supervisor:start_child(
           ?SUPERVISOR,
           {Name, {rabbit_shovel_dyn_worker_sup, start_link, [Name, Def]},
            transient, ?WORKER_WAIT, worker, [rabbit_shovel_dyn_worker_sup]}) of
        {ok,                      _Pid}  -> ok;
        {error, {already_started, _Pid}} -> ok
    end.

child_exists(Name) ->
    lists:any(fun ({N, _, _, _}) -> N =:= Name end,
              mirrored_supervisor:which_children(?SUPERVISOR)).

stop_child(Name) ->
    case get(shovel_worker_autodelete) of
        true -> ok; %% [1]
        _    ->
            ok = mirrored_supervisor:terminate_child(?SUPERVISOR, Name),
            ok = mirrored_supervisor:delete_child(?SUPERVISOR, Name),
            rabbit_shovel_status:remove(Name)
    end.

%% [1] An autodeleting worker removes its own parameter, and thus ends
%% up here via the parameter callback. It is a transient worker that
%% is just about to terminate normally - so we don't need to tell the
%% supervisor to stop us - and as usual if we call into our own
%% supervisor we risk deadlock.
%%
%% See rabbit_shovel_worker:maybe_autodelete/1

%%----------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 3, 10}, []}}.
