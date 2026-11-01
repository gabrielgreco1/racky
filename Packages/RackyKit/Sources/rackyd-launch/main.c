// rackyd-launch: launcher estável do LaunchAgent (T1-24, S-01).
//
// O launchd prende o job registrado ao cdhash do binário do `BundleProgram` (LWCR). Com o `rackyd` como `BundleProgram`,
// toda atualização do app deixa o job em `spawn failed` até um `unregister`+`register` que (a) mata o daemon e (b) só
// funciona depois que o BTM atualiza o registro, o que leva minutos (spike S-01). Por isso o job é
// registrado com ESTE binário, que quase nunca muda (cdhash estável: sem dependências, sem caminhos embutidos, símbolos
// removidos por scripts/build.sh), e ele só faz `exec` do `rackyd` ao lado, com os mesmos argumentos. O daemon novo
// entra na próxima conexão ao socket, sem novo registro. O descritor do socket do launchd (fd 3) é herdado pelo `exec`.
//
// Não altere este arquivo sem necessidade: mudar o launcher muda o cdhash e exige re-registro (o app faz sozinho, com o
// daemon parado).

#include <limits.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// F30: o job do launchd é um só por label e fica preso ao bundle que o registrou. Para apps de pastas diferentes (otter/build,
// /Applications...) não brigarem pelo daemon, o launcher consulta primeiro o ponteiro `bin/rackyd-current` do home do Racky
// (linha 1: caminho absoluto do `rackyd` da versão instalada mais nova; linha 2: build), mantido pelo app. Sem ponteiro
// válido, usa o `rackyd` ao lado (comportamento anterior).
static int pointer_target(char *out, size_t size) {
    char path[PATH_MAX];
    const char *home = getenv("RACKY_HOME");
    if (home && *home) {
        if (snprintf(path, sizeof path, "%s/bin/rackyd-current", home) >= (int)sizeof path) return 0;
    } else {
        home = getenv("HOME");
        if (!home || !*home) return 0;
        if (snprintf(path, sizeof path, "%s/Library/Application Support/Racky/bin/rackyd-current", home) >= (int)sizeof path) return 0;
    }
    FILE *file = fopen(path, "r");
    if (!file) return 0;
    char line[PATH_MAX];
    char *got = fgets(line, sizeof line, file);
    fclose(file);
    if (!got) return 0;
    size_t length = strlen(line);
    while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) line[--length] = 0;
    if (length == 0 || line[0] != '/' || length >= size || access(line, X_OK) != 0) return 0;
    memcpy(out, line, length + 1);
    return 1;
}

int main(int argc, char **argv) {
    (void)argc;
    char target[PATH_MAX];
    if (!pointer_target(target, sizeof target)) {
        char executable[PATH_MAX];
        uint32_t size = (uint32_t)sizeof executable;
        if (_NSGetExecutablePath(executable, &size) != 0) return 70;
        char resolved[PATH_MAX];
        if (realpath(executable, resolved) == NULL) return 70;
        if (snprintf(target, sizeof target, "%s/rackyd", dirname(resolved)) >= (int)sizeof target) return 70;
    }
    argv[0] = target;
    execv(target, argv);
    perror("rackyd-launch: exec rackyd");
    return 70;
}
