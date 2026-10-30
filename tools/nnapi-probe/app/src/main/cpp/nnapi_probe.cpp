#include <android/NeuralNetworks.h>
#include <jni.h>

#include <cmath>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

namespace {

const char* deviceTypeName(int32_t type) {
    switch (type) {
        case ANEURALNETWORKS_DEVICE_CPU: return "CPU";
        case ANEURALNETWORKS_DEVICE_GPU: return "GPU";
        case ANEURALNETWORKS_DEVICE_ACCELERATOR: return "ACCELERATOR";
        case ANEURALNETWORKS_DEVICE_OTHER: return "OTHER";
        default: return "UNKNOWN";
    }
}

const char* statusName(int status) {
    switch (status) {
        case ANEURALNETWORKS_NO_ERROR: return "NO_ERROR";
        case ANEURALNETWORKS_OUT_OF_MEMORY: return "OUT_OF_MEMORY";
        case ANEURALNETWORKS_INCOMPLETE: return "INCOMPLETE";
        case ANEURALNETWORKS_UNEXPECTED_NULL: return "UNEXPECTED_NULL";
        case ANEURALNETWORKS_BAD_DATA: return "BAD_DATA";
        case ANEURALNETWORKS_OP_FAILED: return "OP_FAILED";
        case ANEURALNETWORKS_BAD_STATE: return "BAD_STATE";
        case ANEURALNETWORKS_UNMAPPABLE: return "UNMAPPABLE";
        case ANEURALNETWORKS_OUTPUT_INSUFFICIENT_SIZE: return "OUTPUT_INSUFFICIENT_SIZE";
        case ANEURALNETWORKS_UNAVAILABLE_DEVICE: return "UNAVAILABLE_DEVICE";
        default: return "NNAPI_STATUS_UNKNOWN";
    }
}

struct AddModel {
    ANeuralNetworksModel* model = nullptr;
    int status = ANEURALNETWORKS_NO_ERROR;

    AddModel() {
        uint32_t dims[] = {4};
        ANeuralNetworksOperandType tensor{
            ANEURALNETWORKS_TENSOR_FLOAT32, 1, dims, 0.0f, 0
        };
        ANeuralNetworksOperandType scalar{
            ANEURALNETWORKS_INT32, 0, nullptr, 0.0f, 0
        };

        status = ANeuralNetworksModel_create(&model);
        if (status != ANEURALNETWORKS_NO_ERROR) return;

        status = ANeuralNetworksModel_addOperand(model, &tensor);
        if (status != ANEURALNETWORKS_NO_ERROR) return;
        status = ANeuralNetworksModel_addOperand(model, &tensor);
        if (status != ANEURALNETWORKS_NO_ERROR) return;
        status = ANeuralNetworksModel_addOperand(model, &tensor);
        if (status != ANEURALNETWORKS_NO_ERROR) return;
        status = ANeuralNetworksModel_addOperand(model, &scalar);
        if (status != ANEURALNETWORKS_NO_ERROR) return;

        const int32_t activation = ANEURALNETWORKS_FUSED_NONE;
        status = ANeuralNetworksModel_setOperandValue(
            model, 3, &activation, sizeof(activation));
        if (status != ANEURALNETWORKS_NO_ERROR) return;

        uint32_t inputs[] = {0, 1, 3};
        uint32_t outputs[] = {2};
        status = ANeuralNetworksModel_addOperation(
            model, ANEURALNETWORKS_ADD, 3, inputs, 1, outputs);
        if (status != ANEURALNETWORKS_NO_ERROR) return;

        uint32_t modelInputs[] = {0, 1};
        uint32_t modelOutputs[] = {2};
        status = ANeuralNetworksModel_identifyInputsAndOutputs(
            model, 2, modelInputs, 1, modelOutputs);
        if (status != ANEURALNETWORKS_NO_ERROR) return;

        status = ANeuralNetworksModel_finish(model);
    }

    ~AddModel() {
        if (model) ANeuralNetworksModel_free(model);
    }
};

std::string runOnDevice(const ANeuralNetworksModel* model,
                        const ANeuralNetworksDevice* device,
                        const std::string& name) {
    std::ostringstream out;
    const ANeuralNetworksDevice* devices[] = {device};
    bool supported[] = {false};

    int status = ANeuralNetworksModel_getSupportedOperationsForDevices(
        model, devices, 1, supported);
    if (status != ANEURALNETWORKS_NO_ERROR) {
        out << "  supported-ops query: " << statusName(status)
            << " (" << status << ")\n";
        return out.str();
    }

    out << "  ADD operation supported: " << (supported[0] ? "YES" : "NO") << "\n";
    if (!supported[0]) {
        out << "  compile/execute: SKIPPED (operation unsupported)\n";
        return out.str();
    }

    ANeuralNetworksCompilation* compilation = nullptr;
    status = ANeuralNetworksCompilation_createForDevices(
        model, devices, 1, &compilation);
    if (status != ANEURALNETWORKS_NO_ERROR) {
        out << "  explicit-device compilation: " << statusName(status)
            << " (" << status << ")\n";
        return out.str();
    }

    status = ANeuralNetworksCompilation_setPreference(
        compilation, ANEURALNETWORKS_PREFER_FAST_SINGLE_ANSWER);
    if (status == ANEURALNETWORKS_NO_ERROR) {
        status = ANeuralNetworksCompilation_finish(compilation);
    }
    if (status != ANEURALNETWORKS_NO_ERROR) {
        out << "  explicit-device compilation: " << statusName(status)
            << " (" << status << ")\n";
        ANeuralNetworksCompilation_free(compilation);
        return out.str();
    }
    out << "  explicit-device compilation: PASS\n";

    ANeuralNetworksExecution* execution = nullptr;
    status = ANeuralNetworksExecution_create(compilation, &execution);
    const float a[] = {1.0f, 2.0f, 3.0f, 4.0f};
    const float b[] = {5.0f, 6.0f, 7.0f, 8.0f};
    float result[] = {-1.0f, -1.0f, -1.0f, -1.0f};

    if (status == ANEURALNETWORKS_NO_ERROR) {
        status = ANeuralNetworksExecution_setInput(
            execution, 0, nullptr, a, sizeof(a));
    }
    if (status == ANEURALNETWORKS_NO_ERROR) {
        status = ANeuralNetworksExecution_setInput(
            execution, 1, nullptr, b, sizeof(b));
    }
    if (status == ANEURALNETWORKS_NO_ERROR) {
        status = ANeuralNetworksExecution_setOutput(
            execution, 0, nullptr, result, sizeof(result));
    }
    if (status == ANEURALNETWORKS_NO_ERROR) {
        status = ANeuralNetworksExecution_compute(execution);
    }

    if (status == ANEURALNETWORKS_NO_ERROR) {
        const float expected[] = {6.0f, 8.0f, 10.0f, 12.0f};
        bool valid = true;
        for (size_t i = 0; i < 4; ++i) {
            if (std::fabs(result[i] - expected[i]) > 0.0001f) valid = false;
        }
        out << "  explicit-device execution: " << (valid ? "PASS" : "FAIL")
            << " [";
        for (size_t i = 0; i < 4; ++i) {
            if (i) out << ", ";
            out << result[i];
        }
        out << "]\n";
        if (!valid) out << "  output validation failed\n";
    } else {
        out << "  explicit-device execution: " << statusName(status)
            << " (" << status << ")\n";
    }

    if (execution) ANeuralNetworksExecution_free(execution);
    ANeuralNetworksCompilation_free(compilation);
    return out.str();
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_dev_gabe284_nnapiprobe_MainActivity_nativeProbe(JNIEnv* env, jclass) {
    std::ostringstream out;
    out << "MTK / Android NNAPI diagnostic\n"
        << "Test: one FLOAT32 ADD operation, compiled for each device separately.\n"
        << "This avoids treating framework CPU fallback as accelerator success.\n\n";

    uint32_t count = 0;
    int status = ANeuralNetworks_getDeviceCount(&count);
    if (status != ANEURALNETWORKS_NO_ERROR) {
        out << "ANeuralNetworks_getDeviceCount: " << statusName(status)
            << " (" << status << ")\n";
        return env->NewStringUTF(out.str().c_str());
    }

    out << "NNAPI device count: " << count << "\n\n";
    if (count == 0) {
        out << "RESULT: Android exposed no NNAPI devices.\n";
        return env->NewStringUTF(out.str().c_str());
    }

    AddModel model;
    if (model.status != ANEURALNETWORKS_NO_ERROR) {
        out << "Could not construct ADD test model: "
            << statusName(model.status) << " (" << model.status << ")\n";
        return env->NewStringUTF(out.str().c_str());
    }

    uint32_t acceleratorCount = 0;
    uint32_t acceleratorPassCount = 0;

    for (uint32_t i = 0; i < count; ++i) {
        const ANeuralNetworksDevice* device = nullptr;
        status = ANeuralNetworks_getDevice(i, &device);
        out << "Device " << i << ": ";
        if (status != ANEURALNETWORKS_NO_ERROR || !device) {
            out << "lookup failed: " << statusName(status)
                << " (" << status << ")\n\n";
            continue;
        }

        const char* name = nullptr;
        const char* version = nullptr;
        int32_t type = -1;
        int64_t featureLevel = -1;
        ANeuralNetworksDevice_getName(device, &name);
        ANeuralNetworksDevice_getVersion(device, &version);
        ANeuralNetworksDevice_getType(device, &type);
        ANeuralNetworksDevice_getFeatureLevel(device, &featureLevel);

        const std::string deviceName = name ? name : "(unnamed)";
        out << deviceName << "\n"
            << "  type: " << deviceTypeName(type) << " (" << type << ")\n"
            << "  version: " << (version ? version : "(unknown)") << "\n"
            << "  feature level: " << featureLevel << "\n";

        if (type == ANEURALNETWORKS_DEVICE_ACCELERATOR) ++acceleratorCount;
        const std::string deviceReport = runOnDevice(model.model, device, deviceName);
        out << deviceReport;
        if (type == ANEURALNETWORKS_DEVICE_ACCELERATOR &&
            deviceReport.find("explicit-device execution: PASS") != std::string::npos) {
            ++acceleratorPassCount;
        }
        out << "\n";
    }

    out << "SUMMARY\n"
        << "Accelerator devices exposed: " << acceleratorCount << "\n"
        << "Accelerator ADD execution passes: " << acceleratorPassCount << "\n";
    if (acceleratorPassCount > 0) {
        out << "RESULT: At least one NNAPI accelerator completed the explicitly targeted test.\n";
    } else if (acceleratorCount > 0) {
        out << "RESULT: Accelerator device(s) are exposed, but this test did not prove accelerator execution.\n";
    } else {
        out << "RESULT: No NNAPI accelerator device was exposed; CPU/GPU/other results above are separate.\n";
    }

    return env->NewStringUTF(out.str().c_str());
}
