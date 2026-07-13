#!/bin/bash

ROOT_DIR="$(pwd)"
MANIFEST_PATH="$ROOT_DIR/manifest.yml"

if command -v yq > /dev/null 2>&1; then
	YQ=yq
else
	YQ=./yq
fi

if [ ! -f "$MANIFEST_PATH" ]; then
	echo "error: manifest.yml not found at $MANIFEST_PATH" >&2
	exit 1
fi

MODS=$($YQ length "$MANIFEST_PATH")

build_with_waf() {
	local WAF_ENABLE_VGUI_OPTION=''
	local WAF_ENABLE_AMD64_OPTION=''

	if [ "$GH_CPU_ARCH" == "amd64" ]; then
		WAF_ENABLE_AMD64_OPTION="-8"
	elif [ "$GH_CPU_ARCH" == "i386" ] && ( [ "$GH_CPU_OS" == "win32" ] || [ "$GH_CPU_OS" == "linux" ] || [ "$GH_CPU_OS" == "apple" ] ); then
		python waf --help | grep 'enable-vgui' && WAF_ENABLE_VGUI_OPTION=--enable-vgui
	fi

	python waf --jobs=$(( $(nproc) + 1 )) \
		configure \
			--disable-werror \
			--enable-msvcdeps \
			-T release \
			$WAF_ENABLE_AMD64_OPTION \
			$WAF_ENABLE_VGUI_OPTION \
			$WAF_ENABLE_CROSS_COMPILE_ENV \
			$WAF_CONFIGURE_OPTS \
		install \
			--destdir="$ROOT_DIR/stage_raw" || return 1

	return 0
}

build_with_cmake() {
	rm -rf build/CMakeCache.txt

	cmake -B build -GNinja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$ROOT_DIR/stage/$1" \
		$CMAKE_CONFIGURE_OPTS \
		. || return 1

	ninja -C build install || return 1

	return 0
}

build_mod_source() {
	local REPO_URL="$1"
	local BRANCH_NAME="$2"
	local CUSTOM_DIR="$3"
	local REPO_DIR
	
	if [ -n "$CUSTOM_DIR" ] && [ "$CUSTOM_DIR" != "null" ]; then
		REPO_DIR="$CUSTOM_DIR"
	else
		REPO_DIR=$(basename "$REPO_URL" .git)
	fi

	rm -rf "$REPO_DIR"
	git clone "$REPO_URL" "$REPO_DIR" || return 1

	local DETECTED_GAMEDIR=""

	pushd "$REPO_DIR" || return 1
		git fetch origin "$BRANCH_NAME" || { popd; return 1; }
		git checkout "$BRANCH_NAME" || { popd; return 1; }
		git pull origin "$BRANCH_NAME" 2>/dev/null

		local WORK_DIR="."
		if [[ "$REPO_URL" == *"cry-of-fear-src"* ]]; then
			WORK_DIR="src/cof"
		fi

		pushd "$WORK_DIR" || { popd; return 1; }

			if [ -f "mod_options.txt" ]; then
				if [ "$CUSTOM_DIR" == "xenwar" ]; then
					sed -i 's/XENWARRIOR=OFF/XENWARRIOR=ON/g' mod_options.txt
				fi
				DETECTED_GAMEDIR=$(grep GAMEDIR mod_options.txt | tr '=' ' ' | cut -d' ' -f2 )
			fi

			if [ -z "$DETECTED_GAMEDIR" ]; then
				DETECTED_GAMEDIR="cof"
			fi

			if [ -n "$CUSTOM_DIR" ] && [ "$CUSTOM_DIR" != "null" ]; then
				OUTPUT_ZIP_NAME="${CUSTOM_DIR}"
			else
				OUTPUT_ZIP_NAME="${BRANCH_NAME}"
			fi

			rm -rf "$ROOT_DIR/stage_raw" "$ROOT_DIR/stage/$OUTPUT_ZIP_NAME"
			
			if [ -f "CMakeLists.txt" ]; then
				build_with_cmake "$OUTPUT_ZIP_NAME"
			else
				build_with_waf "$DETECTED_GAMEDIR"
				if [ -d "$ROOT_DIR/stage_raw/$DETECTED_GAMEDIR" ]; then
					mkdir -p "$ROOT_DIR/stage"
					mv "$ROOT_DIR/stage_raw/$DETECTED_GAMEDIR" "$ROOT_DIR/stage/$OUTPUT_ZIP_NAME"
					rm -rf "$ROOT_DIR/stage_raw"
				fi
			fi

			SUCCESS=$?

			if [ "$SUCCESS" -ne 0 ]; then
				popd; popd; return 2
			fi

			mkdir -p "$ROOT_DIR/out"
			printf '{"branch":"%s","commit":"%s","tree":"%s","url":"%s"}\n' \
				"$BRANCH_NAME" \
				"$(git rev-parse HEAD)" \
				"$(git rev-parse HEAD^{tree})" \
				"$(git remote get-url origin)" \
				> "$ROOT_DIR/out/gitinfo-${OUTPUT_ZIP_NAME}-${GH_CPU_OS}-${GH_CPU_ARCH}.json"

		popd || return 1
	popd || return 1

	GAMEDIR="$OUTPUT_ZIP_NAME"
	return 0
}

pack_staged_gamedir() {
	mkdir -p "$ROOT_DIR/out" || return 1

	pushd "$ROOT_DIR/stage/" || return 1
		if [ -d "$2" ]; then
			7z a "$ROOT_DIR/out/$2-$3.zip" "$2" || return 2
			rm -rf "$2"
		fi
	popd || return 1

	return 0
}

for (( i = 0 ; i < MODS ; i++ )); do
	REPO=$($YQ -r ".[$i].repo" "$MANIFEST_PATH")
	BRANCH=$($YQ -r ".[$i].branch" "$MANIFEST_PATH")
	TARGET_DIR=$($YQ -r ".[$i].dir" "$MANIFEST_PATH")
	
	GAMEDIR=""
	
	if [ -n "$TARGET_DIR" ] && [ "$TARGET_DIR" != "null" ]; then
		OUTPUT_ZIP_NAME="${TARGET_DIR}"
	else
		OUTPUT_ZIP_NAME="${BRANCH}"
	fi

	build_mod_source "$REPO" "$BRANCH" "$TARGET_DIR"
	SUCCESS=$?

	if [ $SUCCESS -ne 0 ]; then
		continue
	fi

	pack_staged_gamedir "$GAMEDIR" "$OUTPUT_ZIP_NAME" "$GH_CPU_OS-$GH_CPU_ARCH"
done
