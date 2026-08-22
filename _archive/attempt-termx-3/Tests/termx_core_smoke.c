#include "../Packages/TermXCore/Sources/TermXCore/termx_core.h"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>
int main(void){ int code=-1; termx_spawn_req r={"printf 'termx-ok\n'",-1,STDOUT_FILENO,STDERR_FILENO,"/tmp",NULL,false}; assert(termx_run(&r,&code)==0 && code==0); puts("core smoke: PASS"); return 0; }
