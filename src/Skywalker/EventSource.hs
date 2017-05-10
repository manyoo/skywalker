{-# LANGUAGE JavaScriptFFI #-}
module Skywalker.EventSource (
    EventSource, mkEventSource, onMessage
    ) where

import GHCJS.Types
import GHCJS.Foreign.Callback

import Data.JSString
import JavaScript.Web.MessageEvent
import JavaScript.Web.MessageEvent.Internal

type EventSource = JSVal

foreign import javascript unsafe "new window['EventSource']($1)"
    mkEventSource :: JSString -> IO EventSource

foreign import javascript unsafe "($2)['onmessage'] = $1"
    jsSetOnMessage :: Callback (JSVal -> IO ()) -> EventSource -> IO ()

onMessage :: (MessageEvent -> IO ()) -> EventSource -> IO ()
onMessage cb es = do
    jsCb <- asyncCallback1 (cb . MessageEvent)
    jsSetOnMessage jsCb es
