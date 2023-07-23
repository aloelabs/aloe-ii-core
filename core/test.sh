#!/bin/bash

if [ -z "$CI" ]; then
    CHECK_CONSTANTS=true
    CHECK_STORAGE_LAYOUTS=true
    CHECK_LEDGER_PURITY=true
    CHECK_FORGE_TESTS=true
    CHECK_COVERAGE=true

    # Create a temporary file to store the summary (mimics GitHub Actions environment)
    GITHUB_STEP_SUMMARY=$(mktemp)

    # Define a function to remove the temporary file
    cleanup() {
      echo ""
      cat $GITHUB_STEP_SUMMARY
      rm ${GITHUB_STEP_SUMMARY}
    }

    # Register the cleanup function to be called on exit
    trap cleanup EXIT
fi

# Ensure that `Ledger` and `Lender` have the same storage layouts
if [ "$CHECK_STORAGE_LAYOUTS" = true ]; then
    A=$(mktemp)
    B=$(mktemp)

    forge inspect --pretty "src/Ledger.sol:Ledger" storage-layout >> ${A}
    forge inspect --pretty "src/Lender.sol:Lender" storage-layout >> ${B}

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS (Darwin) sed command
        sed -i '' 's/Lender/Ledger/g' ${B}
    else
        # Linux (including Ubuntu) sed command
        sed -i 's/Lender/Ledger/g' ${B}
    fi
    (cmp -s ${A} ${B})
    are_equivalent=$?
    rm ${A}
    rm ${B}

    if [ "${are_equivalent}" != "0" ]; then
        echo "❌ Ledger and Lender have different storage layouts" >> $GITHUB_STEP_SUMMARY
        exit 1
    fi

    echo "✅ Ledger and Lender have matching storage layouts (all state vars defined in Ledger)" >> $GITHUB_STEP_SUMMARY
fi

# Ensure that `Ledger` has only view & pure functions
if [ "$CHECK_LEDGER_PURITY" = true ]; then
    forge build
    (node 'test.js')
    modifies_state=$?
    if [ "${modifies_state}" != "0" ]; then
        echo "❌ Ledger has non-view/pure functions" >> $GITHUB_STEP_SUMMARY
        exit 1
    fi

    echo "✅ Ledger has only view & pure functions" >> $GITHUB_STEP_SUMMARY
fi

# Run forge tests
if [ "$CHECK_FORGE_TESTS" = true ]; then
    forge test -vv --no-match-contract ".*Gas" --no-match-test "historical"

    echo "✅ forge tests pass" >> $GITHUB_STEP_SUMMARY
fi

# Get coverage. Some files are excluded because they cause stack-too-deep when coverage instrumentation is added
if [ "$CHECK_COVERAGE" = true ]; then
    mv "test/libraries/Volatility.t.sol" "test/libraries/Volatility.ignore"
    mv "test/invariants/LenderHarness.sol" "test/invariants/LenderHarness.ignore"
    mv "test/invariants/LenderInvariants.t.sol" "test/invariants/LenderInvariants.ignore"

    if [ "$CI" = true ]; then
        echo "" >> $GITHUB_STEP_SUMMARY
        echo "### Coverage" >> $GITHUB_STEP_SUMMARY
        forge coverage --report summary --no-match-contract ".*Gas" --no-match-test "historical" >> $GITHUB_STEP_SUMMARY
    else
        forge coverage --report lcov --report summary --no-match-contract ".*Gas" --no-match-test "historical"
    fi

    mv "test/libraries/Volatility.ignore" "test/libraries/Volatility.t.sol"
    mv "test/invariants/LenderHarness.ignore" "test/invariants/LenderHarness.sol"
    mv "test/invariants/LenderInvariants.ignore" "test/invariants/LenderInvariants.t.sol"
fi
