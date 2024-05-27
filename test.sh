#!/bin/bash

# Define SQLite database file
DATABASE_FILE=":memory:"
DATABASE_FILE="test.db"

rm -f $DATABASE_FILE

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

TESTS_TO_COMPARE=("$1")

FAILED_TESTS=0

# Function to execute SQLite CLI with queries and compare outputs
function run_tests() {
    IFS=';'
    for item in $TESTS_TO_COMPARE; do
        echo "Run test: $item"
        OUTPUT=$(sqlite3 $DATABASE_FILE < sql/input_"$item".sql)
        EXPECTED=$(cat expected/output_"$item".txt)
        if [ "$OUTPUT" == "$EXPECTED" ]; then
            echo -e "${GREEN}Test [$item]: PASSED${NC}"
        else
            echo -e "${RED}Test [$item]: FAILED${NC}"
            echo "Expected: [$EXPECTED]"
            echo "Actual: [$OUTPUT]"
            ((FAILED_TESTS++))
        fi
        
    done

    # Check if any test failed and return error if so
    if [ $FAILED_TESTS -gt 0 ]; then
        echo "$FAILED_TESTS test(s) failed."
        exit 1
    fi
}

# Run tests
run_tests
