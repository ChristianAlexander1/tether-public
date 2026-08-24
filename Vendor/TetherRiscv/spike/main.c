/*
 * Tether — Track P8 spike entry point.
 *
 * The task asks for a "minimal main.c loading libriscv". libriscv is a C++20
 * library, so the emulator/loader/benchmark glue lives in tetherspike.cpp;
 * this C file provides the program entry point and forwards argv to it.
 *
 * MIT License (glue code). libriscv itself is BSD-3 (see libriscv/LICENSE).
 */
extern int tetherspike_run(int argc, char **argv);

int main(int argc, char **argv)
{
    return tetherspike_run(argc, argv);
}
