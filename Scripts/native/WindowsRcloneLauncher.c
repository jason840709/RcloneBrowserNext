/* MIT License, Rclone Browser Next contributors.
 * Each child gets its own console group. Swift signals a per-launcher event;
 * CTRL_BREAK lets rclone run its cleanup handlers. Killing this launcher closes
 * its private job object, which also stops the child and its descendants.
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <io.h>

static BOOL WINAPI keep_launcher_alive(DWORD event) {
    return event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT;
}

static int fail(const char *operation) {
    fprintf(stderr, "Rclone Browser Next: %s failed (Windows error %lu).\n", operation, GetLastError());
    return 125;
}

/* Quote for CommandLineToArgvW / the C runtime, never for cmd.exe or PowerShell. */
static wchar_t *command_line(int argc, wchar_t **argv) {
    size_t capacity = 1;
    for (int i = 1; i < argc; ++i) {
        size_t size = wcslen(argv[i]);
        if (capacity > 32763 || size > (32767 - capacity - 4) / 2) return NULL;
        capacity += size * 2 + 4;
    }
    wchar_t *line = (wchar_t *)calloc(capacity, sizeof(wchar_t));
    if (!line) return NULL;
    wchar_t *out = line;
    for (int i = 1; i < argc; ++i) {
        if (i > 1) *out++ = L' ';
        *out++ = L'"';
        const wchar_t *in = argv[i];
        while (*in) {
            size_t slashes = 0;
            while (*in == L'\\') { ++slashes; ++in; }
            if (*in == L'"') {
                for (size_t j = 0; j < slashes * 2 + 1; ++j) *out++ = L'\\';
                *out++ = *in++;
            } else if (!*in) {
                for (size_t j = 0; j < slashes * 2; ++j) *out++ = L'\\';
            } else {
                for (size_t j = 0; j < slashes; ++j) *out++ = L'\\';
                *out++ = *in++;
            }
        }
        *out++ = L'"';
    }
    *out = 0;
    return line;
}

int wmain(int argc, wchar_t **argv) {
    BOOL interactive = argc > 1 && wcscmp(argv[1], L"--interactive") == 0;
    if (interactive) { ++argv; --argc; }
    if (argc < 2) { fputs("Usage: rbn-process-launcher.exe executable [arguments]\n", stderr); return 125; }
    if (interactive) {
        DWORD console_process;
        if (!GetConsoleProcessList(&console_process, 1) && !AllocConsole())
            return fail("Opening the account setup console");
        FILE *stream;
        if (_wfreopen_s(&stream, L"CONIN$", L"r", stdin) ||
            _wfreopen_s(&stream, L"CONOUT$", L"w", stdout) ||
            _wfreopen_s(&stream, L"CONOUT$", L"w", stderr))
            return fail("Opening console input and output");
        SetStdHandle(STD_INPUT_HANDLE, (HANDLE)_get_osfhandle(_fileno(stdin)));
        SetStdHandle(STD_OUTPUT_HANDLE, (HANDLE)_get_osfhandle(_fileno(stdout)));
        SetStdHandle(STD_ERROR_HANDLE, (HANDLE)_get_osfhandle(_fileno(stderr)));
    }
    wchar_t *line = command_line(argc, argv);
    if (!line) { fputs("The Windows command line is too long.\n", stderr); return 125; }

    HANDLE streams[3] = {NULL, NULL, NULL};
    const DWORD identifiers[3] = {STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE};
    for (int i = 0; i < 3; ++i) {
        HANDLE original = GetStdHandle(identifiers[i]);
        if (!original || original == INVALID_HANDLE_VALUE ||
            !DuplicateHandle(GetCurrentProcess(), original, GetCurrentProcess(), &streams[i], 0, TRUE, DUPLICATE_SAME_ACCESS)) {
            free(line); return fail("Copying standard handles");
        }
    }

    wchar_t event_name[100];
    _snwprintf_s(event_name, 100, _TRUNCATE, L"Local\\RcloneBrowserNext.Stop.%lu", GetCurrentProcessId());
    HANDLE stop = CreateEventW(NULL, FALSE, FALSE, event_name);
    if (!stop) { free(line); return fail("Creating the stop event"); }
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        fputs("The process stop event already exists.\n", stderr); free(line); CloseHandle(stop); return 125;
    }

    DWORD console_process;
    BOOL allocated_console = FALSE;
    if (!GetConsoleProcessList(&console_process, 1)) {
        if (!AllocConsole()) { free(line); CloseHandle(stop); return fail("Creating the cleanup console"); }
        allocated_console = TRUE;
        HWND console = GetConsoleWindow();
        if (console) ShowWindow(console, SW_HIDE);
    }
    /* AllocConsole changes standard handles. Restore the private inherited pipe
     * handles before creating the child and before emitting any diagnostic. */
    for (int i = 0; i < 3; ++i) SetStdHandle(identifiers[i], streams[i]);
    SetConsoleCtrlHandler(keep_launcher_alive, TRUE);

    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        free(line); CloseHandle(stop); if (job) CloseHandle(job); return fail("Creating the child job");
    }

    STARTUPINFOEXW startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.StartupInfo.wShowWindow = interactive ? SW_SHOW : SW_HIDE;
    startup.StartupInfo.hStdInput = streams[0];
    startup.StartupInfo.hStdOutput = streams[1];
    startup.StartupInfo.hStdError = streams[2];
    SIZE_T attributes_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attributes_size);
    startup.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attributes_size);
    if (!startup.lpAttributeList || !InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributes_size) ||
        !UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, streams, sizeof(streams), NULL, NULL)) {
        free(line); CloseHandle(stop); CloseHandle(job); return fail("Restricting inherited handles");
    }

    PROCESS_INFORMATION child = {0};
    BOOL started = CreateProcessW(argv[1], line, NULL, NULL, TRUE,
        CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
        NULL, NULL, &startup.StartupInfo, &child);
    DWORD launch_error = GetLastError();
    DeleteProcThreadAttributeList(startup.lpAttributeList);
    free(startup.lpAttributeList); free(line);
    if (!started) {
        CloseHandle(stop); CloseHandle(job); SetLastError(launch_error); return fail("Starting the child");
    }
    if (!AssignProcessToJobObject(job, child.hProcess)) {
        DWORD error = GetLastError(); TerminateProcess(child.hProcess, 125);
        CloseHandle(child.hThread); CloseHandle(child.hProcess); CloseHandle(stop); CloseHandle(job);
        SetLastError(error); return fail("Assigning the child job");
    }
    ResumeThread(child.hThread);
    CloseHandle(child.hThread);
    HANDLE waits[2] = {child.hProcess, stop};
    for (;;) {
        DWORD result = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
        if (result == WAIT_OBJECT_0) break;
        if (result == WAIT_OBJECT_0 + 1) {
            if (!GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, child.dwProcessId)) fail("Sending the cleanup signal");
        } else {
            TerminateJobObject(job, 125); break;
        }
    }
    DWORD exit_code = 125;
    GetExitCodeProcess(child.hProcess, &exit_code);
    CloseHandle(child.hProcess); CloseHandle(stop); CloseHandle(job);
    for (int i = 0; i < 3; ++i) CloseHandle(streams[i]);
    if (allocated_console) FreeConsole();
    return (int)exit_code;
}
