#include <apex/apex.h>
#include <stdio.h>
#include <stdlib.h>

/* CPU-only regression caller. Uses the reader's Apex policy, without an app. */
int main(void) {
    const size_t limit = 8 * 1024 * 1024;
    char *input = malloc(limit + 1);
    if (!input) return 2;
    size_t length = fread(input, 1, limit + 1, stdin);
    if (length > limit || ferror(stdin)) { free(input); return 2; }
    input[length] = 0;
    apex_options options = apex_options_for_mode(APEX_MODE_UNIFIED);
    options.unsafe = true;
    options.enable_plugins = false;
    options.allow_external_plugin_detection = false;
    options.enable_file_includes = false;
    options.enable_metadata_transforms = false;
    options.enable_attributes = false;
    options.enable_markdown_in_html = false;
    options.enable_smart_typography = false;
    options.enable_math = false;
    options.enable_citations = false;
    options.enable_callouts = false;
    options.embed_images = false;
    options.enable_autolink = true;
    options.enable_aria = true;
    options.id_format = 0;
    options.github_pre_lang = false;
    options.generate_header_ids = true;
    char *output = apex_markdown_to_html(input, length, &options);
    free(input);
    if (!output) return 2;
    fputs(output, stdout);
    apex_free_string(output);
    return ferror(stdout) ? 2 : 0;
}
