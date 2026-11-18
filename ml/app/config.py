"""Service settings, read from environment variables."""

from pydantic import Field
from pydantic_settings import BaseSettings

DEFAULT_MAX_IMAGE_BYTES = 15 * 1024 * 1024
DEFAULT_MLX_OCR_MODEL = "mlx-community/Qwen3-VL-8B-Instruct-4bit"


class Settings(BaseSettings):
    """All settings of the service.

    Each field maps to an environment variable with the same name in upper case.
    For example, `ocr_backend` is read from `OCR_BACKEND`.
    """

    ocr_backend: str = "stub"
    # The largest accepted image file, in bytes (`ML_MAX_IMAGE_BYTES`). A phone
    # photo is a few megabytes; 15 MB leaves room for a large HEIC or PNG scan.
    ml_max_image_bytes: int = Field(default=DEFAULT_MAX_IMAGE_BYTES, gt=0)

    # The local MLX backend (OCR_BACKEND=mlx).
    # A Hugging Face model id (downloaded into the Hugging Face cache on first
    # use) or a local folder with MLX weights.
    mlx_ocr_model: str = Field(default=DEFAULT_MLX_OCR_MODEL, min_length=1)
    # The most tokens the model may write for one answer. A receipt with forty
    # items needs about 2,000; a model that keeps repeating a line stops here.
    mlx_ocr_max_tokens: int = Field(default=3072, gt=0)
    # Each photo is scaled down so that its longer side is at most this many
    # pixels before the model sees it. The image-token count grows with the
    # pixel count: a 12-megapixel phone photo would be about 15,000 tokens. At
    # 2048 a phone photo is about 4,000 tokens and a long receipt stays legible.
    mlx_ocr_image_max_side: int = Field(default=2048, ge=256, le=4096)
    # Constrain the model's tokens to the answer's JSON schema (mlx-vlm with
    # llguidance). Turn off only to compare against free generation.
    mlx_ocr_constrained_decoding: bool = True
