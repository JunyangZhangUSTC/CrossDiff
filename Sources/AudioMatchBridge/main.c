// CrossDiff's process adapter around the pinned Olaf fingerprint engine.
// Only private 16 kHz mono Float32 PCM and a new task directory enter this helper.
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <unistd.h>
#include <pthread.h>
#ifdef __APPLE__
#include <mach/mach.h>
#endif
#include "olaf_stream_processor.h"

#define SAMPLE_RATE 16000
#define MAX_SECONDS 7200
#define MAX_RESULTS 512
typedef struct { double ls, le, rs, re; int score; } Segment;
static Segment segments[MAX_RESULTS];
static size_t count;
static int truncated;
static double query_offset;
static double left_duration, right_duration;
static size_t window_results;

#ifdef __APPLE__
// Darwin does not reliably accept a finite RLIMIT_AS. Enforce a resident-memory
// budget in the disposable process instead, independently of fingerprint loops.
static void *memory_watchdog(void *unused) {
    (void)unused;
    for(;;){
        mach_task_basic_info_data_t info;
        mach_msg_type_number_t size=MACH_TASK_BASIC_INFO_COUNT;
        if(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&size)!=KERN_SUCCESS ||
           info.resident_size>768ULL*1024*1024)_exit(4);
        usleep(100000);
    }
    return NULL;
}
#endif

static void result(int score, float qs, float qe, const char *path, uint32_t id, float rs, float re) {
    (void)path; (void)id;
    if(score>0 && ++window_results>=64)truncated=1;
    double a = fmax(0, rs), b = fmin(left_duration, re);
    double c = fmax(0, query_offset + qs), d = fmin(right_duration, query_offset + qe);
    if (score < 20 || !isfinite(a+b+c+d) || b-a < 2 || d-c < 2) return;
    // Consolidate overlapping evidence with the same source-time offset only.
    // Never merge separated islands, or differently aligned repeated material.
    for (size_t i=0;i<count;i++) {
        Segment *s=&segments[i];
        if (fabs((c-a)-(s->rs-s->ls)) < 0.045 && a<=s->le && b>=s->ls && c<=s->re && d>=s->rs) {
            s->ls=fmin(s->ls,a);s->le=fmax(s->le,b);s->rs=fmin(s->rs,c);s->re=fmax(s->re,d);
            if(score>s->score)s->score=score;
            return;
        }
    }
    if(count==MAX_RESULTS){truncated=1;return;}
    segments[count++]=(Segment){a,b,c,d,score};
}

static int raw_fd(const char *path, off_t *size) {
    int fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);
    struct stat st;
    if(fd<0)return -1;
    if(fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_size<4 || st.st_size%4 || st.st_size>(off_t)MAX_SECONDS*SAMPLE_RATE*4){close(fd);errno=EINVAL;return -1;}
    *size=st.st_size;return fd;
}

static int process(Olaf_Runner *runner,const char *path,const char *name,int query) {
    Olaf_Stream_Processor *p=olaf_stream_processor_new(runner,path,name);
    if(!p)return -1;
    olaf_stream_processor_set_suppress_summary(p,true);
    olaf_stream_processor_set_result_header(p,NULL);
    if(query)olaf_stream_processor_set_result_callback(p,result);
    olaf_stream_processor_process(p);
    olaf_stream_processor_destroy(p);
    return 0;
}

static int write_window(int source,const char *destination,off_t start,off_t length) {
    int fd=open(destination,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600);
    if(fd<0)return -1;
    char buffer[65536];
    while(length>0){
        size_t n=length>(off_t)sizeof(buffer)?sizeof(buffer):(size_t)length;
        ssize_t got=pread(source,buffer,n,start);
        if(got<=0){close(fd);return -1;}
        for(ssize_t i=0;i<got;){ssize_t wrote=write(fd,buffer+i,(size_t)(got-i));if(wrote<=0){close(fd);return -1;}i+=wrote;}
        start+=got;length-=got;
    }
    return close(fd);
}

int main(int argc,char **argv) {
    if(argc!=4){fprintf(stderr,"Expected left.pcm right.pcm private-task-directory\n");return 2;}
    // The host also imposes a wall-clock timeout. A failed budget exits this
    // disposable helper; it can never take down the editor/application process.
    struct rlimit cpu={90,90},files={64,64},disk={512ULL*1024*1024,512ULL*1024*1024};
    if(setrlimit(RLIMIT_CPU,&cpu) || setrlimit(RLIMIT_NOFILE,&files) || setrlimit(RLIMIT_FSIZE,&disk))return 3;
#if defined(__APPLE__)
    pthread_t watchdog;if(pthread_create(&watchdog,NULL,memory_watchdog,NULL))return 3;
    pthread_detach(watchdog);
#elif defined(RLIMIT_AS)
    struct rlimit memory={1536ULL*1024*1024,1536ULL*1024*1024};if(setrlimit(RLIMIT_AS,&memory))return 3;
#endif
    off_t left_size,right_size;
    int left=raw_fd(argv[1],&left_size),right=raw_fd(argv[2],&right_size);
    if(left<0||right<0){fprintf(stderr,"Invalid or oversized PCM input\n");return 2;}
    left_duration=(double)left_size/(SAMPLE_RATE*4);right_duration=(double)right_size/(SAMPLE_RATE*4);
    if(left_duration<2 || right_duration<2)truncated=1;
    close(left);
    char db[4096],window[4096];
    if(snprintf(db,sizeof(db),"%s/index",argv[3])>=(int)sizeof(db) || snprintf(window,sizeof(window),"%s/window.pcm",argv[3])>=(int)sizeof(window))return 2;
    // A new directory prevents accidentally sharing or clearing another task's index.
    if(mkdir(db,0700)!=0){fprintf(stderr,"Task index must be new\n");return 2;}
    Olaf_Config *config=olaf_config_default();if(!config)return 3;
    free(config->dbFolder);config->dbFolder=strdup(db);
    config->maxResults=64;config->minMatchCount=20;
    // Observe the entire bounded shortlist before result() applies the 2 s
    // display threshold. Filtering inside Olaf hides short entries and could
    // incorrectly report complete analysis after its 64-result limit is hit.
    config->minMatchTimeDiff=0;
    if(!config->dbFolder)return 3;
    Olaf_Runner *store=olaf_runner_new(OLAF_RUNNER_MODE_STORE,config,NULL,NULL);
    if(!store || process(store,argv[1],"reference",0)!=0)return 3;
    olaf_runner_destroy(store);
    Olaf_Runner *query=olaf_runner_new(OLAF_RUNNER_MODE_QUERY,config,NULL,NULL);if(!query)return 3;
    const off_t width=12*SAMPLE_RATE*4,step=6*SAMPLE_RATE*4;
    for(off_t offset=0;offset<right_size;offset+=step){
        off_t length=right_size-offset;if(length>width)length=width;
        if(length<2*SAMPLE_RATE*4){truncated=1;break;}
        query_offset=(double)offset/(SAMPLE_RATE*4);
        window_results=0;
        if(write_window(right,window,offset,length)!=0 || process(query,window,"query",1)!=0)return 3;
        if(offset+length==right_size)break;
    }
    close(right);unlink(window);
    olaf_runner_destroy(query);olaf_config_destroy(config);
    printf("{\"engine\":\"olaf\",\"partial\":%s,\"matches\":[",truncated?"true":"false");
    for(size_t i=0;i<count;i++){
        Segment *s=&segments[i];
        printf("%s{\"leftStart\":%.6f,\"leftEnd\":%.6f,\"rightStart\":%.6f,\"rightEnd\":%.6f,\"score\":%d}",i?",":"",s->ls,s->le,s->rs,s->re,s->score);
    }
    puts("]}");return 0;
}
