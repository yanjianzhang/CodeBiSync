#!/bin/bash

echo "========================================="
echo "    CodeBiSync M1 本地CI测试流程"
echo "========================================="

# 检查必要工具
echo "1. 检查必要工具..."
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter未安装"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo "❌ Docker未安装"
    exit 1
fi

echo "✅ Flutter和Docker均已安装"

# 检查是否在M1芯片上运行
if [[ $(uname -m) == "arm64" ]]; then
    echo "✅ 检测到Apple Silicon M1芯片"
else
    echo "⚠️ 未检测到M1芯片"
fi

# 获取依赖
echo -e "\n2. 获取项目依赖..."
if flutter pub get; then
    echo "✅ 依赖获取成功"
else
    echo "❌ 依赖获取失败"
    exit 1
fi

# 运行测试
echo -e "\n3. 运行单元测试..."
if flutter test; then
    echo "✅ 单元测试通过"
else
    echo "❌ 单元测试失败"
    exit 1
fi

# 代码格式检查
echo -e "\n4. 检查代码格式..."
if flutter format --set-exit-if-changed .; then
    echo "✅ 代码格式正确"
else
    echo "❌ 代码格式需要调整"
    exit 1
fi

# 代码分析
echo -e "\n5. 代码静态分析..."
if flutter analyze; then
    echo "✅ 代码分析通过"
else
    echo "❌ 代码分析发现问题"
    exit 1
fi

# 构建应用 (使用M1兼容的构建)
echo -e "\n6. 构建macOS应用..."
if arch -arm64 flutter build macos --debug; then
    echo "✅ 应用构建成功"
else
    echo "❌ 应用构建失败"
    exit 1
fi

echo -e "\n========================================="
echo "🎉 所有CI测试通过！"
echo "========================================="