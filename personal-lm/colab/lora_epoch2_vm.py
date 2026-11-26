#!/usr/bin/env python3
"""lora_epoch2_vm.py — epoch 2：在 v2 merged 模型上叠加 LoRA（等效继续训练）。

数据与底座都从 ostore 拉取（fetch_from_ostore.py），不再用 colab upload。
lr 5e-5（继续训练降档），1 epoch，其余同 v2 配方。
"""
import json, subprocess, torch
from unsloth import FastLanguageModel

# 底座 = v2 merged（16bit HF 格式，ostore 拉回拼装）
model, tokenizer = FastLanguageModel.from_pretrained(
    model_name='/content/base/model.safetensors',   # 目录形式在 kick 前整理好
    max_seq_length=1024, load_in_4bit=True)
model = FastLanguageModel.get_peft_model(model, r=32, lora_alpha=64, lora_dropout=0.0,
    target_modules=['q_proj','k_proj','v_proj','o_proj','gate_proj','up_proj','down_proj'],
    use_gradient_checkpointing='unsloth')
model.print_trainable_parameters()

from datasets import load_dataset
ds = load_dataset('json', data_files={'train':'/content/train.jsonl','valid':'/content/valid.jsonl'})
from trl import SFTConfig, SFTTrainer
trainer = SFTTrainer(model=model, tokenizer=tokenizer,
    train_dataset=ds['train'], eval_dataset=ds['valid'],
    dataset_text_field='text', max_seq_length=1024, packing=True,
    args=SFTConfig(per_device_train_batch_size=4, gradient_accumulation_steps=2,
        num_train_epochs=1, learning_rate=5e-5,  # 继续训练：lr 降档（epoch1 用 1e-4）
        lr_scheduler_type='cosine', warmup_ratio=0.03, logging_steps=20,
        eval_strategy='steps', eval_steps=400, save_strategy='steps', save_steps=800,
        output_dir='/content/qwen_lora_out2', bf16=True, report_to='none'))
trainer.train()
print('=== TRAIN DONE ===')
model.save_pretrained_merged('/content/merged_v3', tokenizer, save_method='merged_16bit')
import json; json.dump({'done': True}, open('/content/TRAIN_DONE2.json','w'))
print('=== MERGE DONE ===')
