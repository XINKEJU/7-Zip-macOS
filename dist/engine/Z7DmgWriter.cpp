// Z7DmgWriter.cpp — DMG 磁盘映像创建（调系统 hdiutil，唯一的子进程例外）
//
// 详见 Z7DmgWriter.h。实现：C++ 递归拷贝暂存 + posix_spawn hdiutil。

#include "Z7DmgWriter.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cerrno>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <dirent.h>
#include <unistd.h>
#include <spawn.h>

#include "SevenZipEngine.h"  // z7::Callback / LogLevel

// posix_spawn 需要环境指针；必须是**全局** environ（放进命名空间会变成
// z7::dmg::environ 这个不存在的符号，链接期报 Undefined symbols）。
extern char **environ;

namespace z7 {
namespace dmg {

// ---------------------------------------------------------------------------
// C++ 递归拷贝（避免为暂存再派生 cp，保持子进程数量最小）
// ---------------------------------------------------------------------------
static bool copyFile(const std::string &src, const std::string &dst, std::string &err) {
  FILE *in = fopen(src.c_str(), "rb");
  if (!in) { err = "无法读取：" + src; return false; }
  FILE *out = fopen(dst.c_str(), "wb");
  if (!out) { fclose(in); err = "无法写入：" + dst; return false; }
  const size_t BUF = 1 << 16;
  char *b = new char[BUF];
  size_t n;
  while ((n = fread(b, 1, BUF, in)) > 0) fwrite(b, 1, n, out);
  delete[] b;
  fclose(in);
  fclose(out);
  return true;
}

static bool copyTree(const std::string &src, const std::string &dst, std::string &err) {
  struct stat st;
  if (lstat(src.c_str(), &st) != 0) { err = "无法访问：" + src; return false; }
  if (S_ISDIR(st.st_mode)) {
    if (mkdir(dst.c_str(), 0755) != 0 && errno != EEXIST) {
      err = "无法创建目录：" + dst; return false;
    }
    DIR *d = opendir(src.c_str());
    if (!d) { err = "无法打开目录：" + src; return false; }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
      std::string nm = e->d_name;
      if (nm == "." || nm == "..") continue;
      if (!copyTree(src + "/" + nm, dst + "/" + nm, err)) { closedir(d); return false; }
    }
    closedir(d);
    return true;
  } else if (S_ISREG(st.st_mode)) {
    return copyFile(src, dst, err);
  } else {
    return true;  // 符号链接/设备等：跳过
  }
}

static std::string basenameOf(const std::string &p) {
  size_t s = p.find_last_of('/');
  return (s == std::string::npos) ? p : p.substr(s + 1);
}

// ---------------------------------------------------------------------------
// 运行命令并捕获合并输出（stdout+stderr）
// ---------------------------------------------------------------------------
static int runCapture(const std::vector<std::string> &argv, std::string &out,
                      std::string &err) {
  if (argv.empty()) { err = "空命令"; return -1; }
  int outPipe[2];
  if (pipe(outPipe) != 0) { err = "pipe 失败"; return -1; }

  posix_spawn_file_actions_t acts;
  posix_spawn_file_actions_init(&acts);
  posix_spawn_file_actions_adddup2(&acts, outPipe[1], 1);
  posix_spawn_file_actions_adddup2(&acts, outPipe[1], 2);
  posix_spawn_file_actions_addclose(&acts, outPipe[0]);

  std::vector<char *> c_args;
  for (size_t i = 0; i < argv.size(); i++) c_args.push_back((char *)argv[i].c_str());
  c_args.push_back(NULL);

  pid_t pid;
  int rc = posix_spawn(&pid, argv[0].c_str(), &acts, NULL, c_args.data(), environ);
  posix_spawn_file_actions_destroy(&acts);
  close(outPipe[1]);

  if (rc != 0) {
    close(outPipe[0]);
    err = "无法启动 " + argv[0] + "（posix_spawn 失败）";
    return -1;
  }

  char buf[4096];
  ssize_t n;
  while ((n = read(outPipe[0], buf, sizeof(buf) - 1)) > 0) {
    buf[n] = 0;
    out += buf;
  }
  close(outPipe[0]);

  int status = 0;
  waitpid(pid, &status, 0);
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return -1;
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------
bool CreateDmg(const std::vector<std::string> &utf8InputPaths,
               const std::string &utf8DestArchive, const std::string &volumeName,
               Callback *cb, std::string &error) {
  error.clear();
  if (utf8InputPaths.empty()) { error = "没有待打包的输入"; return false; }

  // 1. 暂存到临时目录
  const char *tmp = getenv("TMPDIR");
  std::string base = (tmp && *tmp) ? tmp : "/tmp";
  while (base.size() > 1 && base[base.size() - 1] == '/') base.erase(base.size() - 1);
  std::string tmpl = base + "/7z-dmg-XXXXXX";
  std::vector<char> buf(tmpl.begin(), tmpl.end());
  buf.push_back('\0');
  if (!mkdtemp(buf.data())) { error = "无法创建临时目录"; return false; }
  std::string stage = std::string(buf.data());
  std::string stageRoot = stage + "/root";

  bool ok = false;
  do {
    if (mkdir(stageRoot.c_str(), 0755) != 0) { error = "无法创建暂存根目录"; break; }
    for (size_t i = 0; i < utf8InputPaths.size(); i++) {
      std::string nm = basenameOf(utf8InputPaths[i]);
      if (nm.empty()) nm = "file";
      // 同名去重
      std::string dst = stageRoot + "/" + nm;
      int d = 2;
      while (access(dst.c_str(), F_OK) == 0) {
        dst = stageRoot + "/" + nm + "-" + std::to_string(d++);
      }
      if (!copyTree(utf8InputPaths[i], dst, error)) break;
    }
    if (!error.empty()) break;

    // 2. 卷标
    std::string vol = volumeName;
    if (vol.empty()) {
      std::string b = basenameOf(utf8DestArchive);
      size_t dot = b.find_last_of('.');
      if (dot != std::string::npos) b = b.substr(0, dot);
      vol = b;
    }

    // 3. 调 hdiutil 生成 UDZO（zlib 压缩、只读）
    if (cb) cb->OnLog(LogLevel::Info, "DMG 创建：调用 hdiutil 生成磁盘映像");
    std::vector<std::string> argv;
    argv.push_back("/usr/bin/hdiutil");
    argv.push_back("create");
    argv.push_back("-ov");
    argv.push_back("-volname");
    argv.push_back(vol);
    argv.push_back("-srcfolder");
    argv.push_back(stageRoot);
    argv.push_back("-format");
    argv.push_back("UDZO");
    argv.push_back(utf8DestArchive);
    std::string out, runErr;
    int code = runCapture(argv, out, runErr);
    if (code != 0) {
      error = "hdiutil 创建 DMG 失败（退出码 " + std::to_string(code) + "）：" +
              (out.empty() ? runErr : out);
      break;
    }
    ok = true;
  } while (false);

  // 4. 清理暂存目录（用 C++ 递归删除，不派生 rm —— 保持子进程数量最小）
  {
    // 仅删除我们创建的暂存目录
    std::vector<std::string> delStack;
    delStack.push_back(stage);
    while (!delStack.empty()) {
      std::string cur = delStack.back();
      delStack.pop_back();
      struct stat st;
      if (lstat(cur.c_str(), &st) != 0) continue;
      if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(cur.c_str());
        if (d) {
          struct dirent *e;
          while ((e = readdir(d)) != NULL) {
            std::string nm = e->d_name;
            if (nm == "." || nm == "..") continue;
            delStack.push_back(cur + "/" + nm);
          }
          closedir(d);
        }
        rmdir(cur.c_str());
      } else {
        unlink(cur.c_str());
      }
    }
  }

  if (ok && cb) {
    struct stat st;
    std::string sz = "?";
    if (stat(utf8DestArchive.c_str(), &st) == 0) sz = std::to_string((uint64_t)st.st_size);
    cb->OnLog(LogLevel::Info, "DMG 创建完成：" + sz + " 字节");
  }
  return ok;
}

}  // namespace dmg
}  // namespace z7
