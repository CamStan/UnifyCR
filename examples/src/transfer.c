/*
 * Copyright (c) 2017, Lawrence Livermore National Security, LLC.
 * Produced at the Lawrence Livermore National Laboratory.
 *
 * Copyright 2017, UT-Battelle, LLC.
 *
 * LLNL-CODE-741539
 * All rights reserved.
 *
 * This is the license for UnifyCR.
 * For details, see https://github.com/LLNL/UnifyCR.
 * Please read https://github.com/LLNL/UnifyCR/LICENSE for full license text.
 */
#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <libgen.h>
#include <getopt.h>
#include <time.h>
#include <mpi.h>
#include <unifycr.h>

#include "testlib.h"

static int rank;
static int total_ranks;
static int rank_worker;
static int debug;

static char* mountpoint = "/unifycr";  /* unifycr mountpoint */
static int unmount;                /* unmount unifycr after running the test */

static char* srcpath;
static char* dstpath;

static unsigned long bufsize = 64 * (1 << 10);

static struct option long_opts[] = {
    { "debug", 0, 0, 'd' },
    { "help", 0, 0, 'h' },
    { "mount", 1, 0, 'm' },
    { "rank", 1, 0, 'r' },
    { "unmount", 0, 0, 'u' },
    { 0, 0, 0, 0},
};

static char* short_opts = "dhm:r:u";

static const char* usage_str =
    "\n"
    "Usage: %s [options...] <source path> <destination path>\n"
    "\n"
    "Available options:\n"
    " -d, --debug                  pause before running test\n"
    "                              (handy for attaching in debugger)\n"
    " -h, --help                   help message\n"
    " -m, --mount=<mountpoint>     use <mountpoint> for unifycr\n"
    "                              (default: /unifycr)\n"
    " -r, --rank=<rank>            use <rank> for transfer (default: 0)\n"
    " -u, --unmount                unmount the filesystem after test\n"
    "\n";

static char* program;

static void print_usage(void)
{
    test_print_once(rank, usage_str, program);
    exit(0);
}

int main(int argc, char** argv)
{
    int ret = 0;
    int ch = 0;
    int optidx = 0;
    struct stat sb = { 0, };

    program = basename(strdup(argv[0]));

    MPI_Init(&argc, &argv);
    MPI_Comm_size(MPI_COMM_WORLD, &total_ranks);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);

    while ((ch = getopt_long(argc, argv,
                             short_opts, long_opts, &optidx)) >= 0) {
        switch (ch) {
        case 'b':
            bufsize = strtoul(optarg, NULL, 0);
            break;

        case 'd':
            debug = 1;
            break;

        case 'm':
            mountpoint = strdup(optarg);
            break;

        case 'r':
            rank_worker = atoi(optarg);
            break;

        case 'u':
            unmount = 1;
            break;

        case 'h':
        default:
            print_usage();
            break;
        }
    }

    if (argc - optind != 2) {
        print_usage();
    }

    srcpath = strdup(argv[optind++]);
    dstpath = strdup(argv[optind++]);

    if (srcpath[strlen(srcpath) - 1] == '/') {
        srcpath[strlen(srcpath) - 1] = '\0';
    }

    if (debug) {
        test_pause(rank, "Attempting to mount");
    }

    ret = unifycr_mount(mountpoint, rank, total_ranks, 0);
    if (ret) {
        test_print(rank, "unifycr_mount failed (return = %d)", ret);
        goto out;
    }

    if (rank_worker >= total_ranks) {
        test_print(rank, "%d is not a valid rank");
        goto out;
    }

    MPI_Barrier(MPI_COMM_WORLD);

    if (rank != rank_worker) {
        goto donothing;
    }

    ret = unifycr_transfer_file(srcpath, dstpath);
    if (ret) {
        test_print(rank, "copy failed (%d: %s)", ret, strerror(ret));
    }

    free(dstpath);
    free(srcpath);

donothing:
    MPI_Barrier(MPI_COMM_WORLD);

    if (unmount) {
        unifycr_unmount();
    }

out:
    MPI_Finalize();

    return ret;
}

