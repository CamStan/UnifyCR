#!/bin/sh

export KB=$((2**10))
export MB=$((2**20))
export GB=$((2**30))
app_id=0

### Project-local sharness code for UnifyCR's integration tests ###

# Override `process_is_running()` function in sharness.d/02-functions.sh.
# Check if a process with a given name is running on each host, retrying up to a
# given number of seconds before giving up.
#
# $1 - Name of a process to check for
# $2 - Number of seconds to wait before giving up
#
# Returns 0 if the named process is found on each host, otherwise returns 1.
process_is_running()
{
    local proc=${1:-"unifycrd"}
    local secs_to_wait=${2:-15}
    local max_loops=$(($secs_to_wait * 2))
    local i=0

    while test "$i" -le "$max_loops"; do
        if test "$($JOB_RUN_ONCE_PER_NODE pidof $proc | wc -w)" -eq "$nnodes"
        then
            return 0
        else
            sleep .5
        fi
        i=$(($i + 1))
    done
    return 1
}

# Override `process_is_not_running()` function in sharness.d/02-functions.sh.
# Check if a process with a given name is not running on each host, retrying up
# to a given number of seconds before giving up.
#
# $1 - Name of a process to check for
# $2 - Number of seconds to wait before giving up
#
# Returns 0 if the named process is not found on each host, otherwise returns 1.
process_is_not_running()
{
    local proc=${1:-"unifycrd"}
    local secs_to_wait=${2:-15}
    local max_loops=$(($secs_to_wait * 2))
    local i=0

    while test "$i" -le "$max_loops"; do
        if test "$($JOB_RUN_ONCE_PER_NODE pidof $proc | wc -w)" -eq 0; then
            return 0
        else
            sleep .5
        fi
        i=$(($i + 1))
    done
    return 1
}

# Override `test_path_is_dir()` function in sharness.sh.
# Checks that a directory of the given name exists and is accessible from each
# host in the allocation. Does NOT need to be a shared directory. (i.e.,
# /dev/shm)
#
# $1 - Path of the directory to check for
# $2 - Can be given to provide a more precise diagnosis
#
# Returns 0 if $1 exists on each host, 1 otherwise.
test_path_is_dir() {
    if ! $($JOB_RUN_ONCE_PER_NODE test -d "$1"); then
        echo "Directory $1 is not an existing directory on all hosts. $2"
        false
    fi
}

# Check if same directory exists and is accessible from each host in the
# allocation.
#
# $1 - Path of the shared directory to check for
# $2 - Can be given to provide a more precise diagnosis
#
# Returns 0 if $1 is a shared directory, 1 otherwise.
test_path_is_shared_dir() {
    # Fail if $1 doesn't exist on each host
    test_path_is_dir "$1" "$2" || return false

    # Get array of inode numbers for $1 on each host
    local l_inodes=($($JOB_RUN_ONCE_PER_NODE stat -c "%i" "$1"))
    local l_length=${#l_inodes[@]}
    local l_first_inode=${l_inodes[0]}

    # Make sure each inode number equals the first inode number, else fail
    for (( i=1; i<$l_length; i++ ))
    do
        if [[ ${l_inodes[$i]} -ne $l_first_inode ]]; then
            echo "Directory $1 is not a shared directory. $2"
            return false
        fi
    done
}

# Check if the provided path ($1) contains a file-per-process of the provided
# file name ($2). Assumes $1 is a shared directory.
#
# This check tacks on "-n" for each process number to the end of the file and
# checks for that files existence in the provided path.
#
# $1 - Path of the shared directory to check for the files
# $2 - File name without the appended process number
# $3 - Can be given to provide a more precise diagnosis
#
# Returns 0 if a file with the given name can be found for each process, 1
# otherwise.
test_path_has_file_per_process() {
    # Make sure $1 is a shared dir
    test_path_is_shared_dir "$1" "$3" || return false

    local l_count=$(( $nres_sets * $nprocs ))
    for (( i=0; i<$l_count; i++ ))
    do
        local l_file_n="${1}/${2}-${i}"
        test_path_is_file $l_file_n "$3" || return false
    done
}


### Unify integration testing helper functions ###

# Find given executable starting in given path, ignoring an optional given path.
#
# $1 - Absolute path of where to start search
# $2 - Executable and optional prefix (i.e., /dir/executable)
# $3 - Optional single path to exclude from search.
#
# Returns path of first executable found with given name and optional prefix
find_executable()
{
    # USAGE: find_executable abs_path *file_name|*path/file_name [prune_path]
    if [[ $# -lt 2 || $# -gt 3 ]]; then
       echo >&2 "$errmsg USAGE: $FUNCNAME abs_path *file|*path/file" \
                "[prune_path]"
       return 1
    fi

    # If dir provided in $3, set it as prune
    [[ -n $3 ]] && local l_prune="-ipath $3 -prune -o"
    local l_target="-path $2 -print -quit"

    local l_ret="$(find $1 -executable $l_prune $l_target)"
    echo $l_ret
    return 0
}

# Calculate the elapsed time between the two given times.
# $2 should be >= $1
#
# $1 - The initial of the two times (in seconds)
# $2 - The latter of the two times (in seconds)
#
# Returns the elapsed time formated as HH:MM:SS
elapsed_time()
{
    # USAGE: elapsed_time start_time_in_seconds end_time_in_seconds
    if [[ $# -ne 2 || $2 -lt $1 ]]; then
        echo >&2 "$errmsg USAGE: $FUNCNAME start_time_in_sec end_time_in_sec"
        return 1
    else
        local l_start_time=$1
        local l_end_time=$2
        local l_diff=$(( l_end_time - l_start_time ))
        # Determining the time $diff is since EPOC allows for it to auto format
        local l_elap=$(date -u --date="@$l_diff" +'%X')
        echo $l_elap
        return 0
    fi
}

# Format $1 bytes to KB, MB, or GB (e.g., format_bytes "1024" becomes 1KB)
#
# $1 - The positive whole number of bytes to format as KB, MB, or GB
#
# Returns $1 formatted as KB, MB, or GB
format_bytes()
{
    # USAGE: format_bytes int
    if [[ -z $1 || $1 -lt 0 ]]; then
        echo >&2 "$errmsg USAGE: $FUNCNAME int"
        return 1
    fi

    if [[ $1 -lt $MB ]]; then # less than 1MB
        if !(($1 % $KB)); then # divisible by 1KB
            echo $(($1/$KB))KB
        else # not divisible by 1KB
            echo $(bc -l <<< "scale=2;$1/(2^10)")KB
        fi
    elif [[ $1 -ge $MB && $1 -lt $GB ]]; then # between 1MB and 1GB
        if !(($1 % $MB)); then # divisible by 1MB
            echo $(($1/$MB))MB
        else # not divisible by 1MB
            echo $(bc -l <<< "scale=2;$1/(2^20)")MB
        fi
    else # greater than or equal to 1GB
        if !(($1 % $GB)); then # divisible by 1GB
            echo $(($1/$GB))GB
        else # not divisible by 1GB
            echo $(bc -l <<< "scale=2;$1/(2^30)")GB
        fi
    fi
    return 0
}

# Build the filename for an example so that if it shows up in the
# $UNIFYCR_MOUNTPOINT, it can be tracked to it's originating test
#
# Also allows testers to get what the filename will be in advance if called
# from test suite. This could be used for posix tests to ensure the file showed
# up in the mount point, as well as for cp/stat tests that potentially need the
# filename from a previous test.
#
# Bear in mind, the filename created in unify_run_test will have a .app suffix.
#
# $1 - The app_name that will be prepended to the formated app_args in the
#      resulting filename
# $2 - The app_args that will be formated and appended to the app_name
# $3 - Optional suffix to append to the end of the file
#
# Returns a string with the spaces removed and hyphens replaced by underscores
# E.g.,: get_filename write-gotcha "-p n1 -n 32 -c 1024 -b 1048576" ".app"
#        becomes
#        write-gotcha_pn1_n32_c1KB_b1MB.app
get_filename()
{
    # USAGE: get_filename app_name app_args [app_suffix]
    if [[ $# -lt 2 || $# -gt 3 || -z $1 || -z $2 ]]; then
        echo >&2 "$errmsg USAGE: $FUNCNAME app_name app_args [app_suffix]"
        return 1
    fi

    # Remove any blank spaces
    local l_remove_spaces=${2//[[:blank:]]/}
    # Replace hyphen(-) with underscore(_)
    local l_replace_hyphens=${l_remove_spaces//-/_}

    # Parse out chunksize and blocksize values
    local l_cs=$(echo $l_replace_hyphens | sed -r 's/.*c([0-9]{3,}).*/\1/')
    local l_bs=$(echo $l_replace_hyphens | sed -r 's/.*b([0-9]{3,}).*/\1/')

    # Format chunksize and blocksize to KB, MB, or GB and replace them in the
    # original string
    local l_replace_chunk=${l_replace_hyphens//$l_cs/$(format_bytes "$l_cs")}
    local l_replace_block=${l_replace_chunk//$l_bs/$(format_bytes "$l_bs")}

    # Finally build the filename
    if [[ -n $3 ]]; then
        # Append suffix if provided
        local l_filename="${1}${l_replace_block}${3}"
    else
        local l_filename="${1}${l_replace_block}"
    fi
    echo $l_filename
}

# Builds the test command that will be executed. Automatically sets any options
# that are always wanted (-vkf and the appropriate -m if posix test or not).
#
# Automatically builds the filename for -f based on the input app_name and
# app_args and has .app appended to the end. This filename then also has .err
# appended and is used for the stderr output file with JOB_RUN_COMMAND.
#
# Args that can be passed in are ([-pncbx][-A|-M|-P|-S|-V]). All other args are
# set automatically.
#
# $1 - Name of the example application to be tested (basetest-runmode)
# $2 - Args for $1 consisting of ([-pncbx][-A|-M|-P|-S|-V]). Encase in quotes.
# $3 - The runmode of test, used to determine if posix and set correct args
#
# Returns the full test command ready to be executed.
build_test_command()
{
    # USAGE: build_test_command app_exe_name app_args([-pncbx][-A|-M|-P|-S|-V])
    if [[ $# -ne 3 ]]; then
        echo >&2 "$errmsg USAGE: $FUNCNAME app_name" \
                 "app_args([-pncbx][-A|-M|-P|-S|-V]) runmode"
        return 1
    fi

    # Autogenerate and format the filename based on app_name and app_args
    local l_filename="$(get_filename $1 "$2")"

    # Add stderr output file to finish building JOB_RUN_COMMAND
    local l_err_filename="$app_err ${UNIFYCR_LOG_DIR}/${l_filename}.err"
    local l_job_run_command="$JOB_RUN_COMMAND $l_err_filename"

    # Build example_command with options that are always wanted. Might need to
    # adjust for other tests (i.e., app-mpiio), or write new functions
    local l_verbose="-v"
    local l_app_id="-a $app_id"

    # Filename needs to be the write file if testing the read example
    local l_app_name=$(echo $1 | sed -r 's/(\w)-.*/\1/')
    if [[ $l_app_name = "read" ]]; then
        local l_app_filename="-f $(get_filename write-$3 "$2").app"
    else
        local l_check="-k"
        local l_app_filename="-f ${l_filename}.app"
    fi

    # Set mountpoint to an existing one if running posix test
    if [[ $3 = "posix" ]]; then
        local l_mount="-U -m $CI_POSIX_MP"
    else
        local l_mount="-m $UNIFYCR_MP"
    fi

    # Assemble full example_command
    local l_app_args="$2 $l_app_id $l_check $l_verbose $l_mount $l_app_filename"
    local l_full_app_name="${UNIFYCR_EXAMPLES}/${1} $l_app_args"

    # Assemble full test_command
    local l_test_command="$l_job_run_command $l_full_app_name"
    echo $l_test_command
}

# Given a example application name and application args, run the example with
# the appropriate MPI runner and args. This function is meant to make running
# the cr, write, read, and writeread examples as easy as possible from the
# testing files.
#
# The build_test_command is called which automatically sets any options that
# are always wanted (-vkf and appropriate -m if posix test or not). The stderr
# output file is also created (based on the filename that is autogenerated) and
# the appropriate option is set for the JOB_RUN_COMMAND.
#
# Args that can be passed in are ([-pncbx][-A|-M|-P|-S|-V]). All other args are
# set automatically, including the filename (which is generated based on the
# input app_name and app_args).
#
# The third parameter is an optional "pass-by-reference" parameter that can
# contain the variable name for the resulting output to be stored in.
# Thus this function can be called in two different way:
#     1. unify_run_test $app_name "$app_args" app_output
#     2. app_output=$(unify_run_test $app_name "app_args")
#
# $1 - Name and runmode of the example application to be tested
# $2 - Args for $1 consisting of ([-pncbx][-A|-M|-P|-S|-V]). Encase in quotes.
# $3 - Optional output variable that is "passed by reference".
#
# Returns the return code of the executed example as well as the output
# produced by running the example.
unify_run_test()
{
    # USAGE: unify_run_test app_name app_args([-pncbx][-A|-M|-P|-S|-V])
    # [output_variable_name]
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        echo >&2 "$errmsg USAGE: $FUNCNAME app_name" \
                 "app_args([-pncbx][-A|-M|-P|-S|-V]) [output_variable_name]"
        return 1
    fi

    # Parse out the runmode and check if valid
    local l_runmode=$(echo $1 | sed -r 's/.*-(\w)/\1/')
    if [[ ! $l_runmode =~ ^(static|gotcha|posix)$ ]]; then
        echo >&2 "$errmsg In $FUNCNAME, runmode not valid in app_name ($1)"
        return 1
    fi

    # Skip this test if posix test and CI_TEST_POSIX=no|NO
    if ! test_have_prereq POSIX && [[ $l_runmode = "posix" ]]; then
        return 42
    fi

    # Fail if user passed in filename, mountpoint, verbose or disable
    # UnifyCR since these are auto added
    local opt='(-f|--file|-m|--mount|-v|--verbose|-U|--disable-unifycr)'
    for s in $2; do
        if [[ $s =~ $opt ]]; then
            echo >&2 "$errmsg Call $FUNCNAME without $opt. Found $s"
            return 1
        fi
    done

    # Finally build and run the test
    local l_test_command=$(build_test_command $1 "$2" $l_runmode)
    say "Results for unifycr_run_test: $l_test_command:"

    # Uncomment to change app_id (-a) for each test. Comment to leave as 0.
    #app_id=$(echo $(($app_id + 1)))

    # Get resulting output and rc of running the test
    local l_app_output; l_app_output="$($l_test_command)"
    local l_rc=$?

    # Put the resulting output in the optional reference parameter
    local l_input_var=$3
    if [[ "$l_input_var" ]]; then
        eval $l_input_var="'$l_app_output'"
    fi

    echo "$l_app_output"
    return $l_rc

}

# Does some post-testing cleanup to include checking if any unifycrd is still
# running and kills them after creating a stack trace. Also removes any files
# that were leftover on the hosts.
cleanup_hosts()
{

    # Capture all output from cleanup in a log
    exec 3>&1 4>&2
    exec &> ${UNIFYCR_LOG_DIR}/hosts.cleanup

    # Get the list of hosts in this allocation
    local l_hl=$(get_hostlist)
    echo "Hostlist: $l_hl"
    local l_app=unifycrd

    echo "+++++ cleaning processes +++++"
    echo " --- collecting stacks ---"
    # unifycrd should have already been terminated at this point, so for each
    # host, check if unifycrd is still running. If so, export the pid for
    # convenience, echo a message, and generate a stack. If not, echo it's not.
    pdsh -w $l_hl '[[ -n $(pgrep "'$l_app'") ]] && \
        (export upid=$(pgrep "'$l_app'") && \
         echo "'$l_app' (pid $upid) still running - creating stack..." && \
         gstack $upid > \
            "'${UNIFYCR_LOG_DIR}'"/"'${l_app}'".pid-${upid}.stack) || \
        echo "'$l_app' not running"'

    echo " --- killing processes ---"
    pdsh -w $l_hl 'pkill -e "'$l_app'"'

    echo "+++++ cleaning files +++++"
    pdsh -w $l_hl 'test -f /dev/shm/svr_id && /bin/cat /dev/shm/svr_id'
    pdsh -w $l_hl 'test -f /dev/shm/unifycrd_id && /bin/cat \
                   /dev/shm/unifycrd_id'
    pdsh -w $l_hl '/bin/rm -rfv /tmp/na_sm /tmp/*unifycr* /var/tmp/*unifycr* \
                   /dev/shm/unifycrd_id /dev/shm/svr_id /dev/shm/*na_sm* \
                   "'${UNIFYCR_SPILLOVER_DATA_DIR}'"/spill*.log \
                   "'${UNIFYCR_SPILLOVER_META_DIR}'"/spill*.log \
                   /dev/shm/*-recv-* /dev/shm/*-req-* /dev/shm/*-super-*'

    # Reset capturing all output
    exec 1>&3 2>&4
}
