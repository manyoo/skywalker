{-# LANGUAGE CPP #-}
module Skywalker.StaticApp (
#if defined(ghcjs_HOST_OS)
  staticApp, defaultFileServerSettings, ssIndices, unsafeToPiece, run, gzip,
  gzipFiles, GzipFiles(..),
#else
  module Network.Wai.Handler.Warp,
  module Network.Wai.Application.Static,
  module WaiAppStatic.Types,
  module Network.Wai.Middleware.Gzip,
#endif
  defaultGZipSettings
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
gzip = undefined
defaultGZipSettings = undefined

data GzipSettings = GzipSettings
    { gzipFiles :: GzipFiles
    }

data GzipFiles = GzipIgnore | GzipCompress | GzipCacheFolder FilePath
    deriving (Show, Eq, Read)

#else
import Network.Wai.Handler.Warp hiding (Connection)
import Network.Wai.Application.Static
import WaiAppStatic.Types
import Network.Wai.Middleware.Gzip
defaultGZipSettings :: GzipSettings
defaultGZipSettings = def
#endif
