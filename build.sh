#!/bin/bash

# Добавляем данные
export DEVICE="munch"
export VERSION="1.0.0"
export PREFIX="e"
export TYPE="early"
export BUILD_TYPE="Testing Only"
#export TGTOKEN=bot_token
#export CHAT_ID=chat_id

# Начало отсчета времени выполнения скрипта
start_time=$(date +%s)

# Удаление каталога "out", если он существует
rm -rf out

# Основной каталог
MAINPATH=/home/runner/work/android_kernel_xiaomi_sm8250/android_kernel_xiaomi_sm8250 # измените, если необходимо

# Каталог ядра
KERNEL_DIR=$MAINPATH
KERNEL_PATH=$KERNEL_DIR/android_kernel_xiaomi_sm8250

BRANCH=$(git branch --show-current)

# Каталоги компиляторов
CLANG_DIR=$KERNEL_DIR/clang21

# Проверка и клонирование, если необходимо
check_and_wget() {
    local dir=$1
    local repo=$2

    if [ ! -d "$dir" ]; then
        echo "Папка $dir не существует. Клонирование $repo."
        mkdir $dir
        cd $dir
        echo "Downloading AOSP Clang..."
        wget $repo &> /dev/null
        tar -zxvf clang-r547379.tar.gz &> /dev/null
        rm -rf clang-r547379.tar.gz
        echo "Done."
        cd ../android_kernel_xiaomi_sm8250
    fi
}

# Клонирование инструментов компиляции, если они не существуют
check_and_wget $CLANG_DIR https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r547379.tar.gz

# Установка переменных PATH
PATH=$CLANG_DIR/bin:$PATH
export PATH
export ARCH=arm64

# Каталог для сборки Perf+
if [ "$DEVICE" = "alioth" ]; then
    PERF_DIR="$KERNEL_DIR/perf"
else
    PERF_DIR="$KERNEL_DIR/perf2"
fi

# Создание каталога Perf+, если его нет
if [ ! -d "$PERF_DIR" ]; then
    mkdir -p "$PERF_DIR"
    
    # Проверка и клонирование Anykernel, если Perf+ не существует
    if [ ! -d "$PERF_DIR/Anykernel" ]; then
        git clone https://github.com/olzhas0986/Anykernel3.git -b perf "$PERF_DIR/Anykernel"
        
        # Перемещение всех файлов из Anykernel в Perf+
        mv "$PERF_DIR/Anykernel/"* "$PERF_DIR/"
        
        # Удаление папки Anykernel
        rm -rf "$PERF_DIR/Anykernel"
    fi
else
    # Если папка Perf+ существует, проверить наличие .git и удалить, если есть
    if [ -d "$PERF_DIR/.git" ]; then
        rm -rf "$PERF_DIR/.git"
    fi
fi

# Экспорт переменных среды
export IMGPATH="$PERF_DIR/Image"
export DTBPATH="$PERF_DIR/dtb"
export DTBOPATH="$PERF_DIR/dtbo.img"
export KBUILD_BUILD_USER="olzhas"
export KBUILD_BUILD_HOST="ubuntu"

# Запись времени сборки
PERF_BUILD_DATE=$(date '+%Y-%m-%d_%H-%M-%S')

# Каталог для результатов сборки
output_dir=out

# Конфигурация ядра
make O="$output_dir" \
            vendor/${DEVICE}_defconfig

# ============================================================
# AR9271 / ath9k_htc USB WiFi Driver
# ============================================================

echo "::group::AR9271 / ath9k_htc Driver Configuration"
echo "[INFO] Enabling AR9271 / ath9k_htc support..."

scripts/config --file "$output_dir/.config" \
    -m MAC80211 \
    -m ATH_COMMON \
    -m ATH9K_HW \
    -m ATH9K_COMMON \
    -m ATH9K_HTC

echo "[INFO] Resolving AR9271 driver dependencies..."

make O="$output_dir" ARCH="$ARCH" olddefconfig

echo
echo "[INFO] AR9271 driver configuration:"
grep -E 'CONFIG_(CFG80211|MAC80211|ATH_COMMON|ATH9K)' \
    "$output_dir/.config"

echo "::endgroup::"

# ============================================================
# AR9271 / ath9k_htc Build Log
# ============================================================

echo "::group::AR9271 / ath9k_htc Build Information"

echo "[INFO] Target chipset : AR9271"
echo "[INFO] Driver        : ath9k_htc"
echo "[INFO] Interface     : USB"
echo "[INFO] Module mode   : M"

echo "[INFO] Expected modules:"
echo "       mac80211.ko"
echo "       ath.ko"
echo "       ath9k_hw.ko"
echo "       ath9k_common.ko"
echo "       ath9k_htc.ko"

echo "::endgroup::"

# ============================================================

    # Компиляция ядра
    make -j $(nproc) \
                O="$output_dir" \
                CC="ccache clang" \
                HOSTCC=gcc \
                LD=ld.lld \
                AS=llvm-as \
                AR=llvm-ar \
                NM=llvm-nm \
                OBJCOPY=llvm-objcopy \
                OBJDUMP=llvm-objdump \
                STRIP=llvm-strip \
                LLVM=1 \
                LLVM_IAS=1 \
                V=$VERBOSE 2>&1 | tee build.log
                

# Предполагается, что переменная DTS установлена ранее в скрипте
find $DTS -name '*.dtb' -exec cat {} + > $DTBPATH
find $DTS -name 'Image' -exec cat {} + > $IMGPATH
find $DTS -name 'dtbo.img' -exec cat {} + > $DTBOPATH

# Завершение отсчета времени выполнения скрипта
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))

cd "$KERNEL_PATH"

# Проверка успешности сборки
if grep -q -E "Ошибка 2|Error 2" build.log; then
    cd "$KERNEL_PATH"
    echo "Error: Build failed with an error"

    curl -s -X POST https://api.telegram.org/bot$TGTOKEN/sendMessage \
    -d chat_id="$CHAT_ID" \
    -d text="Compilation error!"

    curl -s -X POST "https://api.telegram.org/bot$TGTOKEN/sendDocument?chat_id=$CHAT_ID" \
    -F document=@"./build.log"
else
    echo "Total build time: $elapsed_time seconds"

        # ============================================================
    # Copy AR9271 / ath9k_htc modules to Perf+
    # ============================================================

    echo "::group::AR9271 / ath9k_htc modules"

    mkdir -p "$PERF_DIR/AR9271"

    find "$output_dir" -type f \
        \( \
            -name "ath.ko" \
            -o -name "ath9k_hw.ko" \
            -o -name "ath9k_common.ko" \
            -o -name "ath9k_htc.ko" \
            -o -name "mac80211.ko" \
        \) \
        -exec cp -v {} "$PERF_DIR/AR9271/" \;

    echo "[INFO] AR9271 modules:"
    ls -lh "$PERF_DIR/AR9271/"

    MODULE_COUNT=$(find "$PERF_DIR/AR9271" -type f -name "*.ko" | wc -l)

    if [ "$MODULE_COUNT" -ne 5 ]; then
        echo "::error::Expected 5 AR9271 modules, found $MODULE_COUNT"
        find "$PERF_DIR/AR9271" -type f -name "*.ko" -print
        exit 1
    fi

    echo "[OK] All 5 AR9271 modules are ready."
    echo "::endgroup::"

    # Перемещение в каталог Perf+ и создание архива
    cd "$PERF_DIR"
    7z a -mx9 perf-$DEVICE-$PERF_BUILD_DATE.zip * -x!*.zip
    
    curl -s -X POST https://api.telegram.org/bot$TGTOKEN/sendMessage \
    -d chat_id="$CHAT_ID" \
    -d text="Compilation completed successfully! Total build time: $elapsed_time seconds"

    curl -s -X POST "https://api.telegram.org/bot$TGTOKEN/sendDocument?chat_id=$CHAT_ID" \
    -F document=@"./perf-$DEVICE-$PERF_BUILD_DATE.zip" \
    -F caption="perf ${VERSION}${PREFIX} (${BUILD_TYPE}) branch: ${BRANCH}"

    rm -rf perf-$DEVICE-$PERF_BUILD_DATE.zip
fi
