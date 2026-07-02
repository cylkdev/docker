#include <erl_nif.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <string.h>
#include <errno.h>

/* Exported by erts but not declared in erl_nif.h; maps an errno to a stable
   atom-friendly name like "enotty". */
extern char *erl_errno_id(int error);

static ERL_NIF_TERM mk_errno(ErlNifEnv *env) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"),
                          enif_make_atom(env, erl_errno_id(errno)));
}

static ERL_NIF_TERM enable_raw(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int fd;
  if (!enif_get_int(env, argv[0], &fd)) return enif_make_badarg(env);

  struct termios orig, raw;
  if (tcgetattr(fd, &orig) != 0) return mk_errno(env);
  raw = orig;
  cfmakeraw(&raw);
  if (tcsetattr(fd, TCSANOW, &raw) != 0) return mk_errno(env);

  ErlNifBinary bin;
  enif_alloc_binary(sizeof(struct termios), &bin);
  memcpy(bin.data, &orig, sizeof(struct termios));
  return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                          enif_make_binary(env, &bin));
}

static ERL_NIF_TERM restore(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int fd;
  ErlNifBinary bin;
  if (!enif_get_int(env, argv[0], &fd)) return enif_make_badarg(env);
  if (!enif_inspect_binary(env, argv[1], &bin)) return enif_make_badarg(env);
  if (bin.size != sizeof(struct termios)) return enif_make_badarg(env);

  struct termios t;
  memcpy(&t, bin.data, sizeof(struct termios));
  if (tcsetattr(fd, TCSANOW, &t) != 0) return mk_errno(env);
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM winsize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int fd;
  if (!enif_get_int(env, argv[0], &fd)) return enif_make_badarg(env);

  struct winsize ws;
  if (ioctl(fd, TIOCGWINSZ, &ws) != 0) return mk_errno(env);
  return enif_make_tuple2(env, enif_make_atom(env, "ok"),
           enif_make_tuple2(env, enif_make_int(env, ws.ws_row),
                                 enif_make_int(env, ws.ws_col)));
}

static ErlNifFunc funcs[] = {
  {"enable_raw", 1, enable_raw},
  {"restore", 2, restore},
  {"winsize", 1, winsize}
};

ERL_NIF_INIT(Elixir.Docker.Terminal.Termios, funcs, NULL, NULL, NULL, NULL)
