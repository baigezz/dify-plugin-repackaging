#!/bin/bash
# author: Junjie.M

DEFAULT_GITHUB_API_URL=https://github.com
DEFAULT_MARKETPLACE_API_URL=https://marketplace.dify.ai
DEFAULT_PIP_MIRROR_URL=https://pypi.org/simple

GITHUB_API_URL="${GITHUB_API_URL:-$DEFAULT_GITHUB_API_URL}"
MARKETPLACE_API_URL="${MARKETPLACE_API_URL:-$DEFAULT_MARKETPLACE_API_URL}"
PIP_MIRROR_URL="${PIP_MIRROR_URL:-$DEFAULT_PIP_MIRROR_URL}"

CURR_DIR=$(cd "$(dirname "$0")" && pwd)
ARCH_NAME=$(uname -m)
OS_TYPE=$(uname | tr '[:upper:]' '[:lower:]')

CMD_NAME="dify-plugin-${OS_TYPE}-amd64"
if [[ "$ARCH_NAME" == "arm64" || "$ARCH_NAME" == "aarch64" ]]; then
	CMD_NAME="dify-plugin-${OS_TYPE}-arm64"
fi

PIP_PLATFORM_ARGS=""
RAW_PLATFORM=""
PACKAGE_SUFFIX="offline"
PRERELEASE_ALLOW=0

print_usage() {
	echo "usage: $0 [-p platform] [-s package_suffix] [-R] {market|github|local}"
	echo "-p platform: target Python wheel platform, e.g. manylinux2014_x86_64 or manylinux2014_aarch64"
	echo "-s package_suffix: output suffix, e.g. linux-amd64 or linux-arm64"
	echo "-R: allow pre-release versions during uv resolution"
	exit 1
}

install_unzip() {
	if command -v unzip >/dev/null 2>&1; then
		return 0
	fi

	echo "unzip not found; please install unzip first."
	exit 1
}

is_native_target() {
	local target_arch=""

	if [[ -z "$RAW_PLATFORM" ]]; then
		return 0
	fi

	case "$RAW_PLATFORM" in
		*linux*|*manylinux*) [[ "$OS_TYPE" == "linux" ]] || return 1 ;;
		*macos*|*darwin*) [[ "$OS_TYPE" == "darwin" ]] || return 1 ;;
		*) return 1 ;;
	esac

	case "$RAW_PLATFORM" in
		*aarch64*|*arm64*) target_arch="arm64" ;;
		*x86_64*|*amd64*) target_arch="amd64" ;;
		*) return 1 ;;
	esac

	if [[ "$target_arch" == "arm64" ]]; then
		[[ "$ARCH_NAME" == "aarch64" || "$ARCH_NAME" == "arm64" ]]
	else
		[[ "$ARCH_NAME" == "x86_64" || "$ARCH_NAME" == "amd64" ]]
	fi
}

strip_dependency_groups() {
	local pyfile="$1"
	[[ -f "$pyfile" ]] || return 0

	if ! grep -qE '^[[:space:]]*\[dependency-groups\][[:space:]]*$' "$pyfile"; then
		return 0
	fi

	echo "Removing [dependency-groups] from $pyfile..."
	python3 - "$pyfile" <<'PYEOF'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
out = []
in_group = False

for line in lines:
    stripped = line.strip()
    if re.fullmatch(r"\[dependency-groups\]", stripped):
        in_group = True
        continue
    if in_group and re.match(r"^\s*\[", line):
        in_group = False
    if not in_group:
        out.append(line)

path.write_text("".join(out))
PYEOF
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: failed to remove [dependency-groups]"
		exit 1
	fi
	echo "✓ Removed [dependency-groups]"
}

sanitize_requirements_for_download() {
	local reqfile="$1"
	python3 - "$reqfile" <<'PYEOF'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
cleaned = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith("--no-index"):
        continue
    if stripped.startswith("--find-links") or stripped.startswith("-f "):
        continue
    cleaned.append(line)
path.write_text("\n".join(cleaned).rstrip() + "\n")
PYEOF
}

make_requirements_offline() {
	local reqfile="$1"
	python3 - "$reqfile" <<'PYEOF'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
lines = [line for line in lines if not line.strip().startswith("--no-index") and not line.strip().startswith("--find-links")]
path.write_text("--no-index --find-links=./wheels/\n" + "\n".join(lines).rstrip() + "\n")
PYEOF
}

ensure_wheels_in_package() {
	local ignore_path=""
	if [[ -f .difyignore ]]; then
		ignore_path=.difyignore
	elif [[ -f .gitignore ]]; then
		ignore_path=.gitignore
	fi

	if [[ -n "$ignore_path" ]]; then
		python3 - "$ignore_path" <<'PYEOF'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
kept = []
for line in lines:
    normalized = line.strip().lstrip("/")
    if normalized in {"wheels", "wheels/", "requirements.txt"}:
        continue
    kept.append(line)
path.write_text("\n".join(kept).rstrip() + "\n")
PYEOF
	fi
}

market() {
	if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
		echo "Usage: $0 market [plugin author] [plugin name] [plugin version]"
		exit 1
	fi

	local plugin_author="$2"
	local plugin_name="$3"
	local plugin_version="$4"
	local package_path="${CURR_DIR}/${plugin_author}-${plugin_name}_${plugin_version}.difypkg"
	local download_url="${MARKETPLACE_API_URL}/api/v1/plugins/${plugin_author}/${plugin_name}/${plugin_version}/download"

	echo "Downloading ${plugin_author}/${plugin_name}:${plugin_version} from Dify Marketplace..."
	curl -fL -o "$package_path" "$download_url" || {
		echo "✗ Error: download failed: $download_url"
		exit 1
	}

	repackage "$package_path"
}

github() {
	if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
		echo "Usage: $0 github [GitHub repo] [release title] [asset name]"
		exit 1
	fi

	local github_repo="$2"
	local release_title="$3"
	local asset_name="$4"
	if [[ "$github_repo" != "$GITHUB_API_URL"* ]]; then
		github_repo="${GITHUB_API_URL}/${github_repo}"
	fi

	local plugin_name="${asset_name%.difypkg}"
	local package_path="${CURR_DIR}/${plugin_name}-${release_title}.difypkg"
	local download_url="${github_repo}/releases/download/${release_title}/${asset_name}"

	echo "Downloading ${download_url}..."
	curl -fL -o "$package_path" "$download_url" || {
		echo "✗ Error: download failed: $download_url"
		exit 1
	}

	repackage "$package_path"
}

_local() {
	if [[ -z "$2" ]]; then
		echo "Usage: $0 local [difypkg path]"
		exit 1
	fi

	local package_path
	package_path=$(realpath "$2")
	repackage "$package_path"
}

repackage() {
	local package_path="$1"
	local package_file
	local package_name
	package_file=$(basename "$package_path")
	package_name="${package_file%.*}"
	local work_dir="${CURR_DIR}/${package_name}"

	echo ""
	echo "=========================================="
	echo "Dify Plugin Repackaging Tool"
	echo "=========================================="
	echo "Source: $package_path"
	echo "Work directory: $work_dir"

	install_unzip
	rm -rf "$work_dir"
	mkdir -p "$work_dir"
	unzip -oq "$package_path" -d "$work_dir" || {
		echo "✗ Error: failed to extract package"
		exit 1
	}
	cd "$work_dir" || exit 1

	if [[ ! -f pyproject.toml && ! -f requirements.txt ]]; then
		echo "✗ Error: no pyproject.toml or requirements.txt found"
		exit 1
	fi

	if python3 -m pip --version >/dev/null 2>&1; then
		PIP_CMD="python3 -m pip"
	elif command -v pip3 >/dev/null 2>&1; then
		PIP_CMD="pip3"
	elif command -v pip >/dev/null 2>&1; then
		PIP_CMD="pip"
	else
		echo "✗ Error: pip not found"
		exit 1
	fi

	PYTHON_CMD_FOR_UV="python3"
	PY_VERSION_FULL=$(python3 --version 2>&1 | awk '{print $2}')
	PY_MAJOR=$(echo "$PY_VERSION_FULL" | cut -d. -f1)
	PY_MINOR=$(echo "$PY_VERSION_FULL" | cut -d. -f2)
	if [[ "$PY_MAJOR" -eq 3 && "$PY_MINOR" -ge 14 ]]; then
		if command -v python3.12 >/dev/null 2>&1; then
			PYTHON_CMD_FOR_UV="python3.12"
		elif command -v python3.13 >/dev/null 2>&1; then
			PYTHON_CMD_FOR_UV="python3.13"
		fi
	fi

	UV_PY_VERSION=$($PYTHON_CMD_FOR_UV - <<'PYEOF'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PYEOF
)

	local uv_platform=""
	if [[ -n "$RAW_PLATFORM" ]]; then
		case "$RAW_PLATFORM" in
			*linux*|*manylinux*) uv_platform="linux" ;;
			*macos*|*darwin*) uv_platform="macos" ;;
			*win*) uv_platform="windows" ;;
		esac
	fi

	local uv_prerelease_flag=""
	if [[ "$PRERELEASE_ALLOW" -eq 1 ]]; then
		uv_prerelease_flag="--prerelease=allow"
	fi

	echo "Target platform: ${RAW_PLATFORM:-current}"
	echo "Dependency Python: $UV_PY_VERSION"

	# Keep pyproject only long enough to derive runtime requirements. Development
	# groups are removed because plugin-daemon/uv can otherwise resolve them even
	# when the daemon invokes `uv sync --no-dev`.
	if [[ -f pyproject.toml ]]; then
		strip_dependency_groups pyproject.toml
	fi

	if [[ ! -f requirements.txt ]]; then
		if ! command -v uv >/dev/null 2>&1; then
			echo "✗ Error: pyproject.toml exists without requirements.txt, but uv is not installed"
			echo "  Install uv first: python3 -m pip install uv"
			exit 1
		fi

		echo "Generating runtime requirements.txt from pyproject.toml..."
		# Remove an old lock after changing dependency groups, then resolve online on
		# the packaging host. The generated lock is only an intermediate artifact.
		rm -f uv.lock
		uv lock ${uv_platform:+--python-platform "$uv_platform"} \
			--python-version "$UV_PY_VERSION" $uv_prerelease_flag || {
			echo "✗ Error: uv lock failed"
			exit 1
		}
		uv export --format requirements-txt --no-dev --no-hashes -o requirements.txt \
			${uv_platform:+--python-platform "$uv_platform"} \
			--python-version "$UV_PY_VERSION" $uv_prerelease_flag || {
			echo "✗ Error: uv export failed"
			exit 1
		}
	fi

	# An input may itself be an already-repacked package. Remove offline pip flags
	# before downloading so the connected packaging host can resolve dependencies.
	sanitize_requirements_for_download requirements.txt

	rm -rf wheels
	mkdir -p wheels
	echo "Downloading runtime wheels..."
	$PIP_CMD download $PIP_PLATFORM_ARGS --only-binary=:all: --prefer-binary \
		-r requirements.txt -d ./wheels \
		--index-url "$PIP_MIRROR_URL" --trusted-host mirrors.aliyun.com
	if [[ $? -ne 0 ]]; then
		if is_native_target; then
			echo "Prebuilt wheel unavailable; attempting a native source build..."
			env -u PIP_PLATFORM $PIP_CMD wheel --wheel-dir ./wheels --prefer-binary \
			-r requirements.txt --index-url "$PIP_MIRROR_URL" \
			--trusted-host mirrors.aliyun.com || {
				echo "✗ Error: failed to build dependency wheels"
				exit 1
			}
		else
			echo "✗ Error: a required wheel is unavailable for $RAW_PLATFORM"
			echo "  Run the packaging script on the target OS/CPU architecture and retry."
			exit 1
		fi
	fi

	WHEEL_COUNT=$(find ./wheels -maxdepth 1 -type f -name '*.whl' | wc -l | tr -d ' ')
	echo "✓ Downloaded $WHEEL_COUNT wheel packages"

	make_requirements_offline requirements.txt
	ensure_wheels_in_package

	# IMPORTANT for air-gapped Dify 1.17/plugin-daemon:
	# If pyproject.toml is present, daemon prefers project mode (`uv sync`). When
	# no lock is usable, uv performs universal/project resolution and may require
	# dependencies for non-target platforms (for example win32 cffi from gevent),
	# even though the daemon itself is running on Linux. Force requirements mode
	# instead: daemon then uses `uv pip install -r requirements.txt`, whose local
	# find-links points only at the bundled target-platform wheels.
	if [[ -f pyproject.toml ]]; then
		echo "Removing pyproject.toml from final offline package to force requirements mode..."
		rm -f pyproject.toml
	fi
	if [[ -f uv.lock ]]; then
		echo "Removing uv.lock from final offline package..."
		rm -f uv.lock
	fi

	cd "$CURR_DIR" || exit 1
	if [[ ! -x "${CURR_DIR}/${CMD_NAME}" ]]; then
		chmod 755 "${CURR_DIR}/${CMD_NAME}" 2>/dev/null || true
	fi
	if [[ ! -x "${CURR_DIR}/${CMD_NAME}" ]]; then
		echo "✗ Error: packaging CLI not found or not executable: ${CURR_DIR}/${CMD_NAME}"
		exit 1
	fi

	OUTPUT_PACKAGE="${CURR_DIR}/${package_name}-${PACKAGE_SUFFIX}.difypkg"
	echo "Packaging: $OUTPUT_PACKAGE"
	"${CURR_DIR}/${CMD_NAME}" plugin package "$work_dir" \
		-o "$OUTPUT_PACKAGE" --max-size 5120 || {
		echo "✗ Error: packaging failed"
		exit 1
	}

	FILE_SIZE=$(du -h "$OUTPUT_PACKAGE" | cut -f1)
	echo ""
	echo "✓ Package created successfully"
	echo "Location: $OUTPUT_PACKAGE"
	echo "Size: $FILE_SIZE"
	echo "Runtime dependency mode: requirements.txt + bundled wheels"
}

while getopts "p:s:R" opt; do
	case "$opt" in
		p) RAW_PLATFORM="$OPTARG"; PIP_PLATFORM_ARGS="--platform $OPTARG" ;;
		s) PACKAGE_SUFFIX="$OPTARG" ;;
		R) PRERELEASE_ALLOW=1 ;;
		*) print_usage ;;
	esac
done
shift $((OPTIND - 1))

case "${1:-}" in
	market) market "$@" ;;
	github) github "$@" ;;
	local) _local "$@" ;;
	*) print_usage ;;
esac
