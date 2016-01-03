{-# LANGUAGE CPP #-}
module Skywalker.StaticApp (
#if defined(ghcjs_HOST_OS)
  staticApp, defaultFileServerSettings, ssIndices, unsafeToPiece, run
#else
  module Network.Wai.Handler.Warp,
  module Network.Wai.Application.Static,
  module WaiAppStatic.Types
#endif
  ) where

#if defined(ghcjs_HOST_OS)
-- define the stub functions and data types.
-- these functions and data are used in the code available
-- to both server and client. But it's never actually used
-- on the client side. But the compiler requires them to be
-- defined in order to compile
staticApp = undefined
defaultFileServerSettings = undefined

data Piece
data StaticSettings = StaticSettings {
  ssIndices :: [Piece]
  }
unsafeToPiece = undefined
run = undefined
#else
import Network.Wai.Handler.Warp hiding (Connection)
import Network.Wai.Application.Static
import WaiAppStatic.Types
#endif
