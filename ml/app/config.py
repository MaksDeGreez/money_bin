"""Service settings, read from environment variables."""

from pydantic import Field, SecretStr
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

    # The hosted backend (OCR_BACKEND=openrouter): a vision model on OpenRouter,
    # reached only through zero-data-retention endpoints (app/backends/openrouter.py).
    # The API key is a secret: `SecretStr` keeps it out of reprs, logs and errors.
    openrouter_api_key: SecretStr | None = None
    # The model id on OpenRouter (for example "vendor/model-name"). No default:
    # the backend refuses to start without one, so no model is picked silently.
    openrouter_ocr_model: str | None = None
    # Seconds for one receipt: the endpoint list (when it is due to be read
    # again), the call and the repair call together, as a hard deadline. A call
    # is not started with less than 10 seconds left (a repair call: less than
    # the first call took). The default stays under the Rails client's OCR
    # timeout (120 s), so the client never gives up on a call that is still paid.
    openrouter_timeout: float = Field(default=100.0, ge=10, le=600)
    # The most tokens the model may write for one answer (as MLX_OCR_MAX_TOKENS).
    openrouter_max_tokens: int = Field(default=3072, gt=0)
    # The longer side photos are scaled to before they are sent (as
    # MLX_OCR_IMAGE_MAX_SIDE, with the same default, so a comparison sends the
    # same pixels to both backends).
    openrouter_ocr_image_max_side: int = Field(default=2048, ge=256, le=4096)
    # Ask for the answer in the JSON schema (structured outputs) when the model's
    # zero-retention endpoints support it. Turn off only to compare against free
    # generation, or when a provider refuses the schema.
    openrouter_structured_output: bool = True
