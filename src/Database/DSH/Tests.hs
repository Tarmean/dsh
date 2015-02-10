-- | Generic DSH test queries that can be run by any backend for
-- concrete testing.
module Database.DSH.Tests
    ( defaultTests
    , runTests
    , module Database.DSH.Tests.ComprehensionTests
    , module Database.DSH.Tests.CombinatorTests
    ) where

import           Test.Framework

import           Database.DSH.Backend
import           Database.DSH.Tests.CombinatorTests
import           Database.DSH.Tests.ComprehensionTests

-- | Convenience function for running tests
runTests :: Backend c => c -> [c -> Test] -> IO ()
runTests conn tests = defaultMain $ map (\t -> t conn) tests

-- | All available tests in one package.
defaultTests :: Backend c => [c -> Test]
defaultTests =
    [ tests_types
    , tests_tuples
    , tests_join_hunit
    , tests_nest_head_hunit
    , tests_nest_guard_hunit
    , tests_combinators_hunit
    , tests_comprehensions
    , tests_boolean
    , tests_numerics
    , tests_maybe
    , tests_either
    , tests_lists
    , tests_lifted
    ]