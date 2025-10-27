/**
 * @file etch.hpp
 * @brief C++ wrapper for Etch scripting language
 *
 * This header provides a modern C++ interface wrapping the Etch C API.
 * It uses RAII for automatic resource management and provides a more
 * idiomatic C++ interface with exceptions, std::string, and std::function.
 *
 * Example usage:
 * @code
 *   try {
 *     etch::Context ctx;
 *     ctx.compileString("fn main(): int { print(\"Hello!\"); return 0 }");
 *     ctx.execute();
 *   } catch (const etch::Exception& e) {
 *     std::cerr << "Error: " << e.what() << std::endl;
 *   }
 * @endcode
 */

#ifndef ETCH_HPP
#define ETCH_HPP

#include <etch.h>

#include <string>
#include <memory>
#include <stdexcept>
#include <functional>
#include <vector>

namespace etch {

// Forward declarations
class Context;
class Value;

/**
 * Exception thrown by Etch operations
 */
class Exception : public std::runtime_error {
public:
    explicit Exception(const std::string& msg)
        : std::runtime_error(msg) {}
};

/**
 * RAII wrapper for EtchValue
 */
class Value {
public:
    // Constructors
    Value() : value_(etch_value_new_nil()) {}

    explicit Value(int64_t v) : value_(etch_value_new_int(v)) {
        if (!value_) throw Exception("Failed to create int value");
    }

    explicit Value(double v) : value_(etch_value_new_float(v)) {
        if (!value_) throw Exception("Failed to create float value");
    }

    explicit Value(bool v) : value_(etch_value_new_bool(v ? 1 : 0)) {
        if (!value_) throw Exception("Failed to create bool value");
    }

    explicit Value(const std::string& v) : value_(etch_value_new_string(v.c_str())) {
        if (!value_) throw Exception("Failed to create string value");
    }

    explicit Value(const char* v) : value_(etch_value_new_string(v)) {
        if (!value_) throw Exception("Failed to create string value");
    }

    explicit Value(char v) : value_(etch_value_new_char(v)) {
        if (!value_) throw Exception("Failed to create char value");
    }

    // Take ownership of existing EtchValue
    explicit Value(EtchValue v) : value_(v) {}

    // Destructor
    ~Value() {
        if (value_) {
            etch_value_free(value_);
        }
    }

    // Move semantics
    Value(Value&& other) noexcept : value_(other.value_) {
        other.value_ = nullptr;
    }

    Value& operator=(Value&& other) noexcept {
        if (this != &other) {
            if (value_) {
                etch_value_free(value_);
            }
            value_ = other.value_;
            other.value_ = nullptr;
        }
        return *this;
    }

    // Delete copy semantics (values should be explicitly copied if needed)
    Value(const Value&) = delete;
    Value& operator=(const Value&) = delete;

    // Type checking
    bool isInt() const { return value_ && etch_value_is_int(value_); }
    bool isFloat() const { return value_ && etch_value_is_float(value_); }
    bool isBool() const { return value_ && etch_value_is_bool(value_); }
    bool isString() const { return value_ && etch_value_is_string(value_); }
    bool isNil() const { return !value_ || etch_value_is_nil(value_); }

    EtchValueType getType() const {
        if (!value_) return ETCH_TYPE_NIL;
        int type = etch_value_get_type(value_);
        return static_cast<EtchValueType>(type);
    }

    // Value extraction
    int64_t toInt() const {
        int64_t result;
        if (etch_value_to_int(value_, &result) != 0) {
            throw Exception("Value is not an integer");
        }
        return result;
    }

    double toFloat() const {
        double result;
        if (etch_value_to_float(value_, &result) != 0) {
            throw Exception("Value is not a float");
        }
        return result;
    }

    bool toBool() const {
        int result;
        if (etch_value_to_bool(value_, &result) != 0) {
            throw Exception("Value is not a boolean");
        }
        return result != 0;
    }

    std::string toString() const {
        const char* str = etch_value_to_string(value_);
        if (!str) {
            throw Exception("Value is not a string");
        }
        return std::string(str);
    }

    char toChar() const {
        char result;
        if (etch_value_to_char(value_, &result) != 0) {
            throw Exception("Value is not a character");
        }
        return result;
    }

    // Get raw handle (for C API interop)
    EtchValue handle() const { return value_; }

    // Release ownership (caller must free)
    EtchValue release() {
        EtchValue v = value_;
        value_ = nullptr;
        return v;
    }

private:
    EtchValue value_;
};

/**
 * Host function callback type for C++
 * Takes vector of values and returns a value
 */
using HostFunction = std::function<Value(const std::vector<Value>&)>;

/**
 * RAII wrapper for EtchContext
 */
class Context {
public:
    // Default constructor
    Context() : ctx_(etch_context_new()) {
        if (!ctx_) {
            throw Exception("Failed to create Etch context");
        }
    }

    // Constructor with options
    Context(bool verbose, bool debug) : ctx_(etch_context_new_with_options(verbose ? 1 : 0, debug ? 1 : 0)) {
        if (!ctx_) {
            throw Exception("Failed to create Etch context");
        }
    }

    // Destructor
    ~Context() {
        if (ctx_) {
            etch_context_free(ctx_);
        }
    }

    // Delete copy semantics
    Context(const Context&) = delete;
    Context& operator=(const Context&) = delete;

    // Move semantics
    Context(Context&& other) noexcept : ctx_(other.ctx_) {
        other.ctx_ = nullptr;
    }

    Context& operator=(Context&& other) noexcept {
        if (this != &other) {
            if (ctx_) {
                etch_context_free(ctx_);
            }
            ctx_ = other.ctx_;
            other.ctx_ = nullptr;
        }
        return *this;
    }

    // Settings
    void setVerbose(bool verbose) {
        etch_context_set_verbose(ctx_, verbose ? 1 : 0);
    }

    // Compilation
    void compileString(const std::string& source, const std::string& filename = "<string>") {
        if (etch_compile_string(ctx_, source.c_str(), filename.c_str()) != 0) {
            const char* err = etch_get_error(ctx_);
            throw Exception(err ? err : "Compilation failed");
        }
    }

    void compileFile(const std::string& path) {
        if (etch_compile_file(ctx_, path.c_str()) != 0) {
            const char* err = etch_get_error(ctx_);
            throw Exception(err ? err : "Failed to compile file");
        }
    }

    // Execution
    int execute() {
        int result = etch_execute(ctx_);
        if (result != 0) {
            const char* err = etch_get_error(ctx_);
            if (err) {
                throw Exception(err);
            }
        }
        return result;
    }

    // Function calls
    Value callFunction(const std::string& name, const std::vector<Value>& args) {
        std::vector<EtchValue> rawArgs;
        rawArgs.reserve(args.size());
        for (const auto& arg : args) {
            rawArgs.push_back(arg.handle());
        }

        EtchValue result = etch_call_function(
            ctx_,
            name.c_str(),
            rawArgs.empty() ? nullptr : rawArgs.data(),
            static_cast<int>(rawArgs.size())
        );

        if (!result) {
            const char* err = etch_get_error(ctx_);
            throw Exception(err ? err : "Function call failed");
        }

        return Value(result);
    }

    // Global variables
    void setGlobal(const std::string& name, const Value& value) {
        etch_set_global(ctx_, name.c_str(), value.handle());
    }

    Value getGlobal(const std::string& name) {
        EtchValue v = etch_get_global(ctx_, name.c_str());
        if (!v) {
            throw Exception("Global variable not found: " + name);
        }
        return Value(v);
    }

    bool hasGlobal(const std::string& name) {
        EtchValue v = etch_get_global(ctx_, name.c_str());
        if (v) {
            etch_value_free(v);
            return true;
        }
        return false;
    }

    // Host function registration (simple version - C++ lambdas/functions not yet fully integrated)
    void registerFunction(const std::string& name, EtchHostFunction callback, void* userData = nullptr) {
        if (etch_register_function(ctx_, name.c_str(), callback, userData) != 0) {
            throw Exception("Failed to register function: " + name);
        }
    }

    // Get raw handle (for C API interop)
    EtchContext handle() const { return ctx_; }

private:
    EtchContext ctx_;
};

} // namespace etch

#endif // ETCH_HPP
