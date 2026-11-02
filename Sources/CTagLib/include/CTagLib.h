#ifndef CTAGLIB_H
#define CTAGLIB_H

#ifdef __cplusplus
extern "C" {
#endif

/// Reads tags from an audio file as a UTF-8 JSON object.
/// Returns a malloc'd string (free with soundisle_free) or NULL when the file
/// is missing or not a supported audio file. Missing fields are JSON null.
char *soundisle_read_tags(const char *path);

/// Applies the non-null fields of a UTF-8 JSON object to the file's tags.
/// Returns 0 on success. On failure returns non-zero and, when `error` is not
/// NULL, stores a malloc'd UTF-8 message there (free with soundisle_free).
/// The file is written through a temporary copy and atomically replaced, so a
/// failure never leaves a partially written file.
int soundisle_write_tags(const char *path, const char *json, char **error);

/// Frees a string returned by soundisle_read_tags / soundisle_write_tags.
void soundisle_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif
