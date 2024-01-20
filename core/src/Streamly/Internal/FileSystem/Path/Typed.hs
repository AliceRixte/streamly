-- |
-- Module      : Streamly.Internal.FileSystem.Path.Typed
-- Copyright   : (c) 2023 Composewell Technologies
-- License     : BSD3
-- Maintainer  : streamly@composewell.com
-- Portability : GHC

#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
#define OS_PATH WindowsPath
#else
#define OS_PATH PosixPath
#endif

module Streamly.Internal.FileSystem.Path.Typed
    (
      module Streamly.Internal.FileSystem.OS_PATH.Typed
    )
where

import Streamly.Internal.FileSystem.OS_PATH.Typed
