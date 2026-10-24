#ifndef PGEN_PATTERN_PARSE_H
#define PGEN_PATTERN_PARSE_H
/*
 * Pattern file lines (operations.txt), free of openFrameworks and boost so
 * the parser can be built and tested on its own (the maintainer's
 * t/renderer_pattern_parse.t compiles it with AddressSanitizer and UBSan
 * and feeds it malformed and random lines). Nothing here throws or indexes
 * past a container: a malformed value returns false and the caller keeps
 * its previous value.
 */
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <string>
#include <vector>

/* KEY=VALUE. VALUE ends at the next '=', as with the former
   boost::split(el, line, is_any_of("=")) and el[1]. A line without '='
   carries nothing. */
static inline bool patternSplitLine(const std::string &line, std::string &key, std::string &value) {
 size_t eq=line.find('=');
 if(eq == std::string::npos)
  return false;
 key=line.substr(0,eq);
 size_t end=line.find('=',eq+1);
 value=line.substr(eq+1,end == std::string::npos ? std::string::npos : end-eq-1);
 return true;
}

/* A decimal int with an optional sign and nothing else: no spaces, no
   fraction, no trailing characters, within the int range. */
static inline bool patternParseInt(const std::string &text, int &out) {
 if(text.empty())
  return false;
 const char *s=text.c_str();
 if(!(s[0] == '-' || s[0] == '+' || (s[0] >= '0' && s[0] <= '9')))
  return false;
 char *end=nullptr;
 errno=0;
 long v=strtol(s,&end,10);
 if(end == s || (size_t)(end-s) != text.size() || errno == ERANGE || v < INT_MIN || v > INT_MAX)
  return false;
 out=(int)v;
 return true;
}

/* The first COUNT comma-separated ints (extra components are ignored, as
   before). OUT is only written when all COUNT parse. */
static inline bool patternParseInts(const std::string &text, size_t count, int *out) {
 std::vector<int> values;
 size_t start=0;
 while(values.size() < count) {
  if(start > text.size())
   return false;
  size_t comma=text.find(',',start);
  std::string part=text.substr(start,comma == std::string::npos ? std::string::npos : comma-start);
  int v=0;
  if(!patternParseInt(part,v))
   return false;
  values.push_back(v);
  start=(comma == std::string::npos) ? text.size()+1 : comma+1;
 }
 for(size_t i=0;i<count;i++)
  out[i]=values[i];
 return true;
}

#endif
