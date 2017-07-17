{-# LANGUAGE CPP #-}
module Skywalker.Pool (
#if defined(ghcjs_HOST_OS) || defined(client)
    Pool,
    createPool
#else
    module Data.Pool
#endif
  ) where

#if defined(ghcjs_HOST_OS) || defined(client)
data Pool a
createPool = undefined
#else
import Data.Pool
#endif
