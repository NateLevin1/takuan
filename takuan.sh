#!/usr/bin/env bash

trap "exit" INT

if [ "$1" = "" ] || [ "$2" = "" ] || [ "$3" = "" ] || [ "$4" = "" ] || [ "$5" = "" ]; then
    echo "Usage: ./takuan.sh <gitURL> <sha> <victim> <polluter> <package> <module> <iDFlakiesLocalPath> "
    exit 1;
fi

cwd="$(pwd)"
takuanRootDir="$(dirname "$0")"
scriptsDir="$takuanRootDir/scripts"
gitURL="$1"
gitRepoName="$(basename "$gitURL" .git)"
sha="$2"
victim="$3"
polluter="$4"
INSTRUMENT_ONLY="$5"
# arg 6 (module) is handled below
iDFlakiesLocalPath="$7"

if [[ -z "${NO_CLONE}" ]]; then
    git clone "$gitURL"
    cd "$gitRepoName"
    git checkout "$sha"
fi

if [ "${6}" != "." ]; then
    module="$6"
    [[ -z "${NO_INSTALL}" ]] && mvn install -pl "$module" -am -Dmaven.test.skip=true -Ddependency-check.skip=true -Dmaven.javadoc.skip=true
    cd "$module"
else
    [[ -z "${NO_INSTALL}" ]] && mvn install -Dmaven.test.skip=true -Ddependency-check.skip=true -Dmaven.javadoc.skip=true
fi

# TODO: When we switch to `setup.sh` for all setup, remove this
"$scriptsDir/setup.sh" "$gitURL" "$sha" "$module" "$iDFlakiesLocalPath"

if [[ -z "${NO_TEST}" ]]; then
    mvn dependency:copy-dependencies
    mvn package -Dmaven.test.skip=true -Ddependency-check.skip=true -Dmaven.javadoc.skip=true
    mvn compile
    mvn test-compile
    printf "\n\n\n\n\033[0;31mTest Run (Should Fail):\033[0m\n"
    if java -cp "./target/dependency/*:./target/classes:./target/test-classes:$scriptsDir/runner-1.0-SNAPSHOT.jar" in.natelev.runner.Runner "$polluter" "$victim"; then
        printf "\n\n\033[0;31mERR: Test PV run did not fail!\033[0m Are the polluter and victim switched?\n"
        exit 1;
    fi
    printf "\n\n\n\n"
fi

if [[ -z "${NO_GEN}" ]]; then
    if ! INSTRUMENT_ONLY="$5" PPT_SELECT="$5" "$scriptsDir/daikon-gen-victim-polluter.sh" "$victim" "$polluter"
    then
        echo "Getting invariants failed. See error above for more information"
        exit 1
    fi
fi

PROBLEM_INVARIANTS_OUTPUT="$cwd/tmp-$gitRepoName-problem-invariants.csv"
if [[ -z "${NO_DIFF}" ]]; then
    if ! java -cp "$takuanRootDir/target/classes:$DAIKONDIR/daikon.jar" -Xmx6g -XX:+UseG1GC in.natelev.daikondiffvictimpolluter.DaikonDiffVictimPolluter daikon-pv.inv daikon-victim.inv daikon-polluter.inv \
        -o "$cwd/$gitRepoName.dinv" --problem-invariants-output "$PROBLEM_INVARIANTS_OUTPUT"
    then
        echo "Problem invariant finding failed. See error above for more information"
        exit 1
    fi
fi

if [[ -z "${NO_FIND_CLEANER}" ]]; then
    if [[ -f "$PROBLEM_INVARIANTS_OUTPUT" ]]; then
        if ! java -cp "./target/dependency/*:./target/classes:./target/test-classes:$DAIKONDIR/daikon.jar:$scriptsDir/runner-1.0-SNAPSHOT.jar:$CLASSPATH" daikon.Chicory --ppt-omit-pattern='org.junit|junit.framework|junit.runner|com.sun.proxy|javax.servlet|org.hamcrest|in.natelev.runner|groovyjarjarasm.asm' \
            --instrument-only="$INSTRUMENT_ONLY" --problem-invariants-file="$PROBLEM_INVARIANTS_OUTPUT" \
            --cleaners-output-file "$cwd/!-$gitRepoName-cleaners.json" --disable-classfile-version-mismatch-warning \
            in.natelev.runner.Runner all $polluter
        then
            echo "No cleaner found"
            exit 1
        fi

        echo "Cleaners outputted to $cwd/!-$gitRepoName-cleaners.json"
        cat "$cwd/!-$gitRepoName-cleaners.json"

        if [[ -z "${LEAVE_PROBLEM_INVS}" ]]; then
            rm "$PROBLEM_INVARIANTS_OUTPUT"
        fi

        # if no iDFlakiesLocalPath, then warn user and exit
        if [[ -z "${iDFlakiesLocalPath}" ]]; then
            echo "Warning: no iDFlakiesLocalPath provided - will not attempt to find the patch"
        else
            "$scriptsDir/findPatch.sh" "$polluter" "$victim" "$cwd/!-$gitRepoName-cleaners.json" 
        fi
    fi
fi

if [[ -n "${CREATE_GISTS}" ]]; then
    CLIARGS="$@"
    cp "$cwd/$gitRepoName.dinv" "$cwd/!-$gitRepoName.dinv"
    gh gist create "$cwd/!-$gitRepoName.dinv" "$cwd/!-$gitRepoName-cleaners.json" daikon-pv.log daikon-victim.log daikon-polluter.log --web --desc "Generated by takuan.sh: ./takuan.sh $CLIARGS"
    rm "$cwd/!-$gitRepoName.dinv"
fi

echo -e "\x1B[32m✓ Completed Takuan. Took ""$SECONDS""s.\x1B[0m"
