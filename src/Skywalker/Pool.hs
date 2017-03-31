{-# LANGUAGE CPP #-}
module Skywalker.Pool (
#if defined(ghcjs_HOST_OS)
    Pool,
    createPool
#else
    module Data.Pool
#endif
  ) where

#if defined(ghcjs_HOST_OS)
data Pool a
createPool = undefined
#else
import Data.Pool
#endif
