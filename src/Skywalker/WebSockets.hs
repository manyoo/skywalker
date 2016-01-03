{-# LANGUAGE CPP #-}
module Skywalker.WebSockets (
#if defined(ghcjs_HOST_OS)
  websocketsOr, defaultConnectionOptions
#else
  module Network.WebSockets,
  module Network.Wai.Handler.WebSockets
#endif
  ) where

#if defined(ghcjs_HOST_OS)
websocketsOr = undefined
defaultConnectionOptions = undefined
#else
import Network.WebSockets hiding (runClient)
import Network.Wai.Handler.WebSockets
#endif
