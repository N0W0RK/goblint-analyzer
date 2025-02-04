//PARAM: --set ana.activated[+] deadlock --disable asm_is_nop
#include <unistd.h>
#include <pthread.h>
#include <stdio.h>

pthread_mutex_t lock_a;
pthread_mutex_t lock_b;

void *proc_a(void *arg) {
    pthread_mutex_lock(&lock_a);
    asm ("nop" : "=g" (lock_a));
    sleep(1);
    pthread_mutex_lock(&lock_b);
    pthread_exit(NULL);
}

void *proc_b(void *arg) {
    pthread_mutex_lock(&lock_b);
    sleep(1);
    pthread_mutex_lock(&lock_a);
    return NULL;
}

int main(void) {
    int x;
    pthread_t a, b;
    pthread_create(&a, NULL, proc_a, NULL);
    proc_b(NULL);
    // this will remove lock_a from must_lockset
    puts("no deadlock!");
}
