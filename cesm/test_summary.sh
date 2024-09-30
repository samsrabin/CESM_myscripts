#!/bin/bash
set -e

#############################################################################################

script="test_summary.sh"
function usage {
    echo " "
    echo -e "usage: $script [-h|--help] [-i|--only-show-issues] [-n|--quiet-nlfail] [-p|--quiet-pending]\n"
}

# Set defaults
quiet_pending=0
quiet_nlfail=0
only_show_issues=0

# Args while-loop
while [ "$1" != "" ];
do
    case $1 in

        # Print help
        -h | --help)
            usage
            exit 0
            ;;

        # Only show tests with issues (i.e., don't print pending, pass, or expected fail)
        -i | --only-show-issues)
            only_show_issues=1
            ;;

        # Don't print NLFAIL tests
        -n | --quiet-nlfail)
            quiet_nlfail=1
            ;;

        # Shortcuts for -i -n
        -in | -ni)
            only_show_issues=1
            quiet_nlfail=1
            ;;

        # Don't print pending tests
        -p  | --quiet-pending)
            quiet_pending=1
            ;;

        *)
            echo "$script: illegal option $1"
            usage
            exit 1 # error
            ;;
    esac
    shift
done

# Check run_sys_tests command for limiters
namelists_only=0
if [[ $(head -n 1 SRCROOT_GIT_STATUS) == *"--namelists-only"* ]]; then
    namelists_only=1
fi

#############################################################################################

rm -f accounted_for_* all_tests

tmpfile=.test_summary.$(date "+%Y%m%d%H%M%S%N")
excl_dir_pattern="SSPMATRIXCN_.*\.step\w+|ERI.*\.ref\w+|SSP.*\.ref\w+|RXCROPMATURITY.*\.\w+"
$(get_cs.status) \
    | grep -vE "${excl_dir_pattern}" \
    > ${tmpfile}
ntests=$(grep "Overall:" ${tmpfile} | wc -l)

# We don't want the script to exit if grep finds no matches
set +e

# Account for completed tests
if [[ ${namelists_only} -eq 1 ]]; then
    filename_pass="accounted_for_nlpass"
else
    grep -E "FAIL.*BASELINE exception" ${tmpfile} | awk '{print $2}' > accounted_for_baselineException
    grep -E "FAIL.*CREATE_NEWCASE" ${tmpfile} | grep -v "EXPECTED" | awk '{print $2}' > accounted_for_createCase
    grep -E "FAIL.*SHAREDLIB_BUILD" ${tmpfile} | grep -v "EXPECTED" | awk '{print $2}' > accounted_for_sharedlibBuild
    grep -E "FAIL.*MODEL_BUILD" ${tmpfile} | grep -v "EXPECTED" | awk '{print $2}' > accounted_for_modelBuild
    grep -E "FAIL.*RUN" ${tmpfile} | grep -v "EXPECTED" | awk '{print $2}' > accounted_for_runFail
    filename_pass="accounted_for_pass"
    grep -E "PASS.*BASELINE" ${tmpfile} | awk '{print $2}' > ${filename_pass} 
    grep -E "FAIL.*COMPARE_base_rest" ${tmpfile} | grep -v "EXPECTED" | awk '{print $2}' > accounted_for_compareBaseRest
    grep -E "FAIL.*COMPARE_base_modpes" ${tmpfile} | grep -v "EXPECTED" | awk '{print $2}' > accounted_for_compareBaseModpes
    grep -E "FAIL.*BASELINE.*otherwise" ${tmpfile} | awk '{print $2}' > accounted_for_fieldlist
    grep -E "FAIL.*BASELINE.*some baseline files were missing" ${tmpfile} | awk '{print $2}' > accounted_for_missingBaselineFiles
    grep -E "FAIL.*BASELINE.*baseline directory.*does not exist" ${tmpfile} | awk '{print $2}' > accounted_for_missingBaselineDir
    grep -E "EXPECTED FAILURE" ${tmpfile} | awk '{print $2}' > accounted_for_expectedFail
    grep -E "FAIL.*XML*" ${tmpfile} | awk '{print $2}' > accounted_for_xmlFail
fi

# Add a file for tests that failed in NLCOMP, even if they're also in another accounted_for file
grep -E "FAIL.*NLCOMP" ${tmpfile} | awk '{print $2}' > accounted_for_nlfail

if [[ ${namelists_only} -eq 0 ]]; then
    touch accounted_for_truediffs
    for e in $(grep -E "FAIL.*BASELINE.*DIFF" ${tmpfile} | awk '{print $2}'); do
        # Runs that fail because of restart diffs (can?) also show up as true baseline diffs. Only keep them as the former.
        if [[ $(grep ${e} accounted_for_compareBaseRest | wc -l) -gt 0 ]]; then
            continue
        fi
        # Some expected-fail runs complete but have diffs. Note those.
        if [[ $(grep ${e} accounted_for_expectedFail | wc -l) -gt 0 ]]; then
            echo "${e} (EXPECTED FAIL)" >> accounted_for_truediffs
            continue
        fi
        echo ${e} >> accounted_for_truediffs
    done
fi

# Account for pending tests
touch accounted_for_pend
pattern="Overall: PEND"
for t in $(grep -E "${pattern}" ${tmpfile} | awk '{print $1}' | sort); do
    if [[ ! -e accounted_for_expectedFail || $(grep $t accounted_for_expectedFail | wc -l) -eq 0 ]]; then
        d="$(ls -d $t.[GC0-9]* | grep -vE "${excl_dir_pattern}")"
        nfound=$(echo $d | wc -w)
        if [[ ${nfound} -eq 0 ]]; then
            echo "No directories found for test $t" >&2
            exit 1
        elif [[ ${nfound} -gt 1 ]]; then
            echo "Too many matching directories found for test $t" >&2
            exit 1
        fi
        f=$d/TestStatus.log
        build_nl_failed="build-namelist failed"
        result="$(grep -o "SETUP PASSED\|${build_nl_failed}" $f | tail -n 1)"
        if [[ "${result}" == "${build_nl_failed}" ]]; then
            echo $t >> accounted_for_nlbuildfail
        elif [[ ${namelists_only} -eq 0 && $(grep $t accounted_for_nlfail | wc -l) -eq 0 ]]; then
            echo $t >> accounted_for_pend
        fi
    fi
done

set -e

testlist="$(grep "Overall" ${tmpfile} | awk '{print $1}')"

missing_tests=
for d in ${testlist}; do
    if [[ "$(grep $d accounted_for* | wc -l)" -eq 0 ]]; then
        missing_tests="${missing_tests} $d"
    fi
done

truly_unaccounted=""
for d in ${missing_tests}; do
    n_fail_lines=$(grep $d ${tmpfile} | grep FAIL | grep -v "UNEXPECTED: expected FAIL" | wc -l)
    if [[ ${n_fail_lines} -eq 0 ]]; then
        echo $d >> ${filename_pass}
    else
        truly_unaccounted="${truly_unaccounted} $d"
    fi
done
touch not_accounted_for
for d in ${truly_unaccounted}; do
    grep $d ${tmpfile} >> not_accounted_for
done

for f in accounted*; do
    [[ $f == accounted_for_pend ]] && continue
    n=$(wc -l $f | cut -d" " -f1)
    if [[ $f == accounted_for_nlfail && ${quiet_nlfail} -eq 1 ]]; then
        echo $f
        [[ $n -gt 0 ]] && echo "   $n tests had namelist diffs"
        echo " "
        continue
    fi
    if [[ ${only_show_issues} -eq 1 ]]; then
        if [[ $f == ${filename_pass} ]]; then
            echo $f
            [[ $n -gt 0 ]] && echo "   $(wc -l $f | cut -d" " -f1) tests passed"
            echo " "
            continue
        fi
        if [[ $f == accounted_for_expectedFail ]]; then
            echo $f
            [[ $n -gt 0 ]] && echo "   $(wc -l $f | cut -d" " -f1) tests failed as expected"
            echo " "
            continue
        fi
    fi
    echo $f
    cat $f | sort
    echo " "
done

# Print these last
echo accounted_for_pend
if [[ ${quiet_pending} -eq 0 && ${only_show_issues} -eq 0 ]]; then
    cat accounted_for_pend
else
    n=$(wc -l accounted_for_pend | cut -d" " -f1)
    [[ $n -gt 0 ]] && echo "   $n tests pending"
fi
echo " "
echo not_accounted_for
cat not_accounted_for
echo " "

cat *accounted_for* | grep -v "(EXPECTED FAIL)" | sort | uniq > all_tests
n=$(cat all_tests | wc -l)
if [[ ${n} -ne ${ntests} ]]; then
    echo "ERROR: EXPECTED $ntests TESTS; MISSING $((ntests - n))" >&2
    rm ${tmpfile}
    exit 1
fi

rm ${tmpfile}
exit 0
