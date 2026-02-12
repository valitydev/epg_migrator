%%%-------------------------------------------------------------------
%% @doc tpl public API
%% @end
%%%-------------------------------------------------------------------

-module(epg_migrator_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    epg_migrator_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
