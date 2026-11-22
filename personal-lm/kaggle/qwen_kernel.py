# Kaggle kernel: Qwen3-1.7B 个人风格 QLoRA（unsloth）
# 数据: kaggle dataset cloud_bundle.tar.gz（lora/{train,valid}.jsonl）
# 产出: /kaggle/working/merged/qwen3-1.7b-personal/（merge_16bit，mac mlx_lm.convert 直接用）
import os, glob

# ---- 解包数据集 ----
zips = glob.glob("/kaggle/input/**/*.tar.gz", recursive=True)
assert zips, "cloud_bundle.tar.gz not found"
os.system(f"mkdir -p /kaggle/working/data && tar -xzf '{zips[0]}' -C /kaggle/working && cp -r /kaggle/working/cloud/* /kaggle/working/data/")
print("data ready:", os.listdir("/kaggle/working/data"))

# !pip install unsloth（kernel 内执行，避免 metadata 里放 pip 依赖等待）
os.system("pip install -q unsloth")

from unsloth import FastLanguageModel
import torch
from datasets import load_dataset
from trl import SFTConfig, SFTTrainer

DATA = "/kaggle/working/data"
model, tokenizer = FastLanguageModel.from_pretrained(
    model_name="Qwen/Qwen3-1.7B",
    max_seq_length=1024,
    load_in_4bit=True,
)
model = FastLanguageModel.get_peft_model(
    model,
    r=32,
    lora_alpha=64,
    lora_dropout=0.0,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    use_gradient_checkpointing="unsloth",
)
model.print_trainable_parameters()

ds = load_dataset("json", data_files={"train": f"{DATA}/lora/train.jsonl", "valid": f"{DATA}/lora/valid.jsonl"})
trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=ds["train"],
    eval_dataset=ds["valid"],
    dataset_text_field="text",
    max_seq_length=1024,
    packing=True,
    args=SFTConfig(
        per_device_train_batch_size=4,
        gradient_accumulation_steps=2,
        num_train_epochs=2,
        learning_rate=2e-4,
        lr_scheduler_type="cosine",
        warmup_ratio=0.03,
        logging_steps=20,
        eval_strategy="steps", eval_steps=200,
        save_strategy="steps", save_steps=1000,
        output_dir="/kaggle/working/qwen_lora_out",
        bf16=True,
        report_to="none",
    ),
)
trainer.train()

# ---- 快速试写（个人风格验证）----
FastLanguageModel.for_inference(model)
for prefix in ["## cf 迭代复盘\n- ", "写个脚本批量检查"]:
    inputs = tokenizer(prefix, return_tensors="pt").to("cuda")
    out = model.generate(**inputs, max_new_tokens=64, do_sample=True, temperature=0.8, top_p=0.9)
    print("PREFIX:", prefix.replace("\n", " | "))
    print("OUT   :", tokenizer.decode(out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)[:200])

# ---- merge 保存（16bit 完整模型）----
merged = "/kaggle/working/merged/qwen3-1.7b-personal"
model.save_pretrained_merged(merged, tokenizer, save_method="merged_16bit")
print("merged ->", merged)
