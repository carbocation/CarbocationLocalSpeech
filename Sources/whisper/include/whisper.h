#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WHISPER_SAMPLE_RATE 16000

#ifdef __cplusplus
extern "C" {
#endif

struct whisper_context;
struct whisper_state;

typedef int32_t whisper_pos;
typedef int32_t whisper_token;
typedef int32_t whisper_seq_id;

enum ggml_log_level {
    GGML_LOG_LEVEL_NONE  = 0,
    GGML_LOG_LEVEL_DEBUG = 1,
    GGML_LOG_LEVEL_INFO  = 2,
    GGML_LOG_LEVEL_WARN  = 3,
    GGML_LOG_LEVEL_ERROR = 4,
    GGML_LOG_LEVEL_CONT  = 5,
};

typedef bool (*ggml_abort_callback)(void * data);
typedef void (*ggml_log_callback)(enum ggml_log_level level, const char * text, void * user_data);
typedef void (*whisper_new_segment_callback)(struct whisper_context * ctx, struct whisper_state * state, int n_new, void * user_data);
typedef void (*whisper_progress_callback)(struct whisper_context * ctx, struct whisper_state * state, int progress, void * user_data);
typedef bool (*whisper_encoder_begin_callback)(struct whisper_context * ctx, struct whisper_state * state, void * user_data);

typedef struct whisper_token_data {
    whisper_token id;
    whisper_token tid;
    float p;
    float plog;
    float pt;
    float ptsum;
    int64_t t0;
    int64_t t1;
    int64_t t_dtw;
    float vlen;
} whisper_token_data;

typedef void (*whisper_logits_filter_callback)(
    struct whisper_context * ctx,
    struct whisper_state * state,
    const whisper_token_data * tokens,
    int n_tokens,
    float * logits,
    void * user_data);

typedef struct whisper_ahead {
    int n_text_layer;
    int n_head;
} whisper_ahead;

typedef struct whisper_aheads {
    size_t n_heads;
    const whisper_ahead * heads;
} whisper_aheads;

enum whisper_alignment_heads_preset {
    WHISPER_AHEADS_NONE,
    WHISPER_AHEADS_N_TOP_MOST,
    WHISPER_AHEADS_CUSTOM,
    WHISPER_AHEADS_TINY_EN,
    WHISPER_AHEADS_TINY,
    WHISPER_AHEADS_BASE_EN,
    WHISPER_AHEADS_BASE,
    WHISPER_AHEADS_SMALL_EN,
    WHISPER_AHEADS_SMALL,
    WHISPER_AHEADS_MEDIUM_EN,
    WHISPER_AHEADS_MEDIUM,
    WHISPER_AHEADS_LARGE_V1,
    WHISPER_AHEADS_LARGE_V2,
    WHISPER_AHEADS_LARGE_V3,
    WHISPER_AHEADS_LARGE_V3_TURBO,
};

struct whisper_context_params {
    bool  use_gpu;
    bool  flash_attn;
    int   gpu_device;
    bool dtw_token_timestamps;
    enum whisper_alignment_heads_preset dtw_aheads_preset;
    int dtw_n_top;
    struct whisper_aheads dtw_aheads;
    size_t dtw_mem_size;
};

enum whisper_gretype {
    WHISPER_GRETYPE_END = 0,
    WHISPER_GRETYPE_ALT = 1,
    WHISPER_GRETYPE_RULE_REF = 2,
    WHISPER_GRETYPE_CHAR = 3,
    WHISPER_GRETYPE_CHAR_NOT = 4,
    WHISPER_GRETYPE_CHAR_RNG_UPPER = 5,
    WHISPER_GRETYPE_CHAR_ALT = 6,
};

typedef struct whisper_grammar_element {
    enum whisper_gretype type;
    uint32_t value;
} whisper_grammar_element;

typedef struct whisper_vad_params {
    float threshold;
    int min_speech_duration_ms;
    int min_silence_duration_ms;
    float max_speech_duration_s;
    int speech_pad_ms;
    float samples_overlap;
} whisper_vad_params;

enum whisper_sampling_strategy {
    WHISPER_SAMPLING_GREEDY,
    WHISPER_SAMPLING_BEAM_SEARCH,
};

struct whisper_full_params {
    enum whisper_sampling_strategy strategy;
    int n_threads;
    int n_max_text_ctx;
    int offset_ms;
    int duration_ms;
    bool translate;
    bool no_context;
    bool no_timestamps;
    bool single_segment;
    bool print_special;
    bool print_progress;
    bool print_realtime;
    bool print_timestamps;
    bool token_timestamps;
    float thold_pt;
    float thold_ptsum;
    int max_len;
    bool split_on_word;
    int max_tokens;
    bool debug_mode;
    int audio_ctx;
    bool tdrz_enable;
    const char * suppress_regex;
    const char * initial_prompt;
    bool carry_initial_prompt;
    const whisper_token * prompt_tokens;
    int prompt_n_tokens;
    const char * language;
    bool detect_language;
    bool suppress_blank;
    bool suppress_nst;
    float temperature;
    float max_initial_ts;
    float length_penalty;
    float temperature_inc;
    float entropy_thold;
    float logprob_thold;
    float no_speech_thold;
    struct {
        int best_of;
    } greedy;
    struct {
        int beam_size;
        float patience;
    } beam_search;
    whisper_new_segment_callback new_segment_callback;
    void * new_segment_callback_user_data;
    whisper_progress_callback progress_callback;
    void * progress_callback_user_data;
    whisper_encoder_begin_callback encoder_begin_callback;
    void * encoder_begin_callback_user_data;
    ggml_abort_callback abort_callback;
    void * abort_callback_user_data;
    whisper_logits_filter_callback logits_filter_callback;
    void * logits_filter_callback_user_data;
    const whisper_grammar_element ** grammar_rules;
    size_t n_grammar_rules;
    size_t i_start_rule;
    float grammar_penalty;
    bool vad;
    const char * vad_model_path;
    whisper_vad_params vad_params;
};

const char * whisper_version(void);
const char * whisper_print_system_info(void);
struct whisper_context_params whisper_context_default_params(void);
struct whisper_context * whisper_init_from_file_with_params(const char * path_model, struct whisper_context_params params);
void whisper_free(struct whisper_context * ctx);
struct whisper_full_params whisper_full_default_params(enum whisper_sampling_strategy strategy);
int whisper_full(struct whisper_context * ctx, struct whisper_full_params params, const float * samples, int n_samples);
int whisper_tokenize(struct whisper_context * ctx, const char * text, whisper_token * tokens, int n_max_tokens);
int whisper_n_text_ctx(struct whisper_context * ctx);
int whisper_n_audio_ctx(struct whisper_context * ctx);
whisper_token whisper_token_eot(struct whisper_context * ctx);
int whisper_full_n_segments(struct whisper_context * ctx);
int whisper_full_n_segments_from_state(struct whisper_state * state);
int whisper_full_lang_id(struct whisper_context * ctx);
const char * whisper_lang_str(int id);
int64_t whisper_full_get_segment_t0(struct whisper_context * ctx, int i_segment);
int64_t whisper_full_get_segment_t0_from_state(struct whisper_state * state, int i_segment);
int64_t whisper_full_get_segment_t1(struct whisper_context * ctx, int i_segment);
int64_t whisper_full_get_segment_t1_from_state(struct whisper_state * state, int i_segment);
const char * whisper_full_get_segment_text(struct whisper_context * ctx, int i_segment);
const char * whisper_full_get_segment_text_from_state(struct whisper_state * state, int i_segment);
int whisper_full_n_tokens(struct whisper_context * ctx, int i_segment);
int whisper_full_n_tokens_from_state(struct whisper_state * state, int i_segment);
const char * whisper_full_get_token_text(struct whisper_context * ctx, int i_segment, int i_token);
const char * whisper_full_get_token_text_from_state(struct whisper_context * ctx, struct whisper_state * state, int i_segment, int i_token);
whisper_token whisper_full_get_token_id(struct whisper_context * ctx, int i_segment, int i_token);
whisper_token_data whisper_full_get_token_data(struct whisper_context * ctx, int i_segment, int i_token);
whisper_token_data whisper_full_get_token_data_from_state(struct whisper_state * state, int i_segment, int i_token);
float whisper_full_get_token_p(struct whisper_context * ctx, int i_segment, int i_token);
float whisper_full_get_token_p_from_state(struct whisper_state * state, int i_segment, int i_token);
void whisper_log_set(ggml_log_callback log_callback, void * user_data);

#ifdef __cplusplus
}
#endif
