// This is an open source non-commercial project. Dear PVS-Studio, please check
// it.
// PVS-Studio Static Code Analyzer for C, C++ and C#: http://www.viva64.com
//

#pragma once

namespace e4 {

//
//====== BEGIN FEATURES ======
//

#ifndef E4FEATURE_COLOR_CONSOLE
#define E4FEATURE_COLOR_CONSOLE 0
#endif

#ifndef E4FEATURE_FS
#define E4FEATURE_FS 0
#endif

#ifndef E4FEATURE_ERLDIST
#define E4FEATURE_ERLDIST 0
#endif

#ifndef E4FEATURE_FLOAT
#define E4FEATURE_FLOAT 0
#endif

#ifndef E4FEATURE_BIGNUM
#define E4FEATURE_BIGNUM 0
#endif

#ifndef E4FEATURE_MAPS
#define E4FEATURE_MAPS 0
#endif

#ifndef E4FEATURE_HOTCODELOAD
#define E4FEATURE_HOTCODELOAD 0
#endif

namespace feat {
constexpr bool color_console() { return (E4FEATURE_COLOR_CONSOLE != 0); }
constexpr bool fs() { return (E4FEATURE_FS != 0); }
constexpr bool distribution() { return (E4FEATURE_ERLDIST != 0); }
constexpr bool floating_point() { return (E4FEATURE_FLOAT != 0); }
constexpr bool bignum() { return (E4FEATURE_BIGNUM != 0); }
constexpr bool maps() { return (E4FEATURE_MAPS != 0); }
constexpr bool hot_code_load() { return (E4FEATURE_HOTCODELOAD != 0); }
} // ns feat

//
//====== END FEATURES ======
//

constexpr bool DEBUG_MODE = (E4DEBUG != 0);


#if defined(__arm__)
  #define E4_ARM 1
#else
  #define E4_ARM 0
#endif


#undef BIG_ENDIAN
#undef LITTLE_ENDIAN
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define E4_BIG_ENDIAN 0
constexpr bool BIG_ENDIAN = false;
#else
#define E4_BIG_ENDIAN 1
constexpr bool BIG_ENDIAN = true;
#endif

#define DECL_EXCEPTION(NAME)                               \
  class NAME##Error : public e4::RuntimeError {         \
   public:                                                 \
    NAME##Error(const char* e) : e4::RuntimeError(e) {} \
    virtual const char* what() const noexcept;             \
  };
#define IMPL_EXCEPTION(NAME)                       \
  const char* NAME##Error::what() const noexcept { \
    return e4::RuntimeError::what();            \
  }
#define DECL_IMPL_EXCEPTION(NAME) DECL_EXCEPTION(NAME) IMPL_EXCEPTION(NAME)

#define E4_NORETURN __attribute__((noreturn))

#if __cplusplus > 201402L
  #if __has_cpp_attribute(nodiscard)
    #define E4_NODISCARD [[nodiscard]]
  #elif __has_cpp_attribute(gnu::warn_unused_result)
    #define E4_NODISCARD [[gnu::warn_unused_result]]
  #endif
#else
  #define E4_NODISCARD
#endif

#if __cplusplus > 201402L
  #if __has_cpp_attribute(maybe_unused)
    #define E4_MAYBE_UNUSED [[maybe_unused]]
  #elif __has_cpp_attribute(gnu::unused)
    #define E4_MAYBE_UNUSED [[gnu::unused]]
  #endif
#else
  #define E4_MAYBE_UNUSED
#endif

#if __has_cpp_attribute(fallthrough)
#define E4_FALLTHROUGH [[fallthrough]]
#elif __has_cpp_attribute(clang::fallthrough)
#define E4_FALLTHROUGH [[clang::fallthrough]]
#else
#define E4_FALLTHROUGH
#endif

}  // ns e4
