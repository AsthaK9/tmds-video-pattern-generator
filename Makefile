#==============================================================================
# Makefile for TMDS Video Test-Pattern Generator
# Supports Icarus Verilog and Verilator (auto-detected or overridden with SIM=)
#==============================================================================

SHELL := /bin/bash

# Simulator auto-detection (Verilator 5 if installed, else Icarus Verilog)
HAVE_VERILATOR := $(shell which verilator 2>/dev/null)
HAVE_IVERILOG  := $(shell which iverilog 2>/dev/null)

ifeq ($(strip $(HAVE_VERILATOR)),)
  SIM ?= iverilog
else
  SIM ?= verilator
endif

PYTHON ?= python3

# Source files
RTL_SRCS := rtl/video_timing.sv \
            rtl/tmds_encoder.sv \
            rtl/pattern_gen.sv  \
            rtl/cdc_sync.sv     \
            rtl/reg_bank.sv     \
            rtl/top.sv

OUT_DIR := out

.PHONY: all sim decode clean sim_timing sim_encoder sim_top help

all: sim decode
	@echo "============================================================"
	@echo ">>> ALL WORKFLOW STEPS COMPLETED SUCCESSFULLY <<<"
	@echo "============================================================"

sim: sim_timing sim_encoder sim_top

# 1. Video Timing Testbench
sim_timing:
	@mkdir -p $(OUT_DIR)
ifeq ($(SIM),iverilog)
	iverilog -g2012 -Wall -o $(OUT_DIR)/sim_video_timing rtl/video_timing.sv tb/tb_video_timing.sv
	vvp $(OUT_DIR)/sim_video_timing
else
	verilator --binary --timing -Wall -Wno-fatal --top tb_video_timing rtl/video_timing.sv tb/tb_video_timing.sv --prefix Vtb_video_timing -Mdir $(OUT_DIR)/obj_timing
	$(OUT_DIR)/obj_timing/Vtb_video_timing
endif

# 2. TMDS Encoder Testbench
sim_encoder:
	@mkdir -p $(OUT_DIR)
ifeq ($(SIM),iverilog)
	iverilog -g2012 -Wall -o $(OUT_DIR)/sim_tmds_encoder rtl/tmds_encoder.sv tb/tb_tmds_encoder.sv
	vvp $(OUT_DIR)/sim_tmds_encoder
else
	verilator --binary --timing -Wall -Wno-fatal --top tb_tmds_encoder rtl/tmds_encoder.sv tb/tb_tmds_encoder.sv --prefix Vtb_tmds_encoder -Mdir $(OUT_DIR)/obj_encoder
	$(OUT_DIR)/obj_encoder/Vtb_tmds_encoder
endif

# 3. System Top Testbench
sim_top:
	@mkdir -p $(OUT_DIR)
ifeq ($(SIM),iverilog)
	iverilog -g2012 -Wall -o $(OUT_DIR)/sim_top $(RTL_SRCS) tb/tb_top.sv
	vvp $(OUT_DIR)/sim_top
else
	verilator --binary --timing -Wall -Wno-fatal --top tb_top $(RTL_SRCS) tb/tb_top.sv --prefix Vtb_top -Mdir $(OUT_DIR)/obj_top
	$(OUT_DIR)/obj_top/Vtb_top
endif

# 4. Golden Model Comparison & PNG Conversion
decode:
	$(PYTHON) scripts/frame_to_png.py

clean:
	rm -rf $(OUT_DIR)/* sim_*
	@echo "[CLEAN] Cleaned build and output artifacts."

help:
	@echo "Available targets:"
	@echo "  make all         - Run simulation suite and golden verification"
	@echo "  make sim         - Run all 3 SystemVerilog testbenches"
	@echo "  make sim_timing  - Run video_timing testbench"
	@echo "  make sim_encoder - Run TMDS encoder testbench"
	@echo "  make sim_top     - Run system top testbench"
	@echo "  make decode      - Run Python golden model and montage generator"
	@echo "  make clean       - Remove simulation executables and artifacts"
	@echo "Variables:"
	@echo "  SIM=iverilog|verilator (detected: $(SIM))"
