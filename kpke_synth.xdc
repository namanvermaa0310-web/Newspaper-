## =============================================================================
## kpke_synth.xdc -- constraints for Phase 4 out-of-context synthesis
## Target: xc7k325tffg900-2
## =============================================================================
## PURPOSE: get a real WNS number and a real utilisation report for the Phase 4
## datapath. This is NOT a board build and will NOT produce a usable bitstream.
##
## WHY THERE ARE NO PACKAGE_PIN LINES
## kpke_top exposes about 330 top-level port bits -- an 8-bit service bus, a
## 13-bit slot address, an 11-bit byte address and a 256-bit rho_out among
## them. It is an INTERNAL block meant to be driven by kpke_engine, not a chip
## top. Assigning those to physical pins would be inventing constraints for an
## interface that will never leave the die, and it is exactly the mistake made
## early in this project when 48 coefficient-bus bits were mapped to arbitrary
## FMC pins.
##
## When Phase 4 is ready for the board it gets the same treatment Phases 1-3
## got: a thin wrapper (IBUFDS + MMCM + reset synchroniser + UART bridge) that
## exposes four real pins, and THAT wrapper gets a pin XDC.
## =============================================================================

## -----------------------------------------------------------------------------
## Clock. 10 ns = 100 MHz, matching the rate Phases 1-3 are timing-closed at.
## -----------------------------------------------------------------------------
create_clock -period 10.000 -name clk [get_ports clk]

## Reset is asynchronous and is synchronised inside the board wrapper (which
## does not exist yet at this level), so do not let it distort the report.
set_false_path -from [get_ports rst_n]

## -----------------------------------------------------------------------------
## Unconstrained I/O
## -----------------------------------------------------------------------------
## With no PACKAGE_PIN or IOSTANDARD on the ports, implementation would stop on
##   [DRC NSTD-1] Unspecified I/O Standard
##   [DRC UCIO-1] Unconstrained Logical Port
## Those checks exist to stop you shipping a bitstream with undefined I/O
## levels -- entirely correct for a board build, and irrelevant here because no
## bitstream is being produced. Downgrading them to warnings lets place-and-
## route complete so the timing report is real.
##
## If either of these ever fires on a design you DO intend to put on hardware,
## fix the pins. Do not copy these two lines into a board XDC.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

## -----------------------------------------------------------------------------
## Keep the I/O paths out of the timing picture
## -----------------------------------------------------------------------------
## Without input/output delays the tool would otherwise report meaningless
## paths from unconstrained pads. What matters here is the INTERNAL logic:
## the NTT butterfly, the Keccak round, the basemul chain and the memory
## paths. False-pathing the boundary keeps the WNS number about those.
set_false_path -from [all_inputs]  -to [all_registers]
set_false_path -from [all_registers] -to [all_outputs]

## -----------------------------------------------------------------------------
## Configuration (harmless here, required if this is ever extended to a build)
## -----------------------------------------------------------------------------
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 2.5 [current_design]

## =============================================================================
## HOW TO READ THE RESULT
## =============================================================================
## WNS positive  -> Phase 4 meets timing at 100 MHz. Record the margin, not
##                  just the sign: +0.05 ns and +3 ns are very different risks
##                  once temperature and process variation are included.
##
## WNS negative  -> record the number AND the worst path's startpoint and
##                  endpoint. Which module it lands in decides the fix:
##                    keccak_round        -> split theta+rho+pi from chi+iota
##                    basemul / ntt       -> already one multiplier per stage;
##                                           look for a memory path instead
##                    poly_slots          -> the 2-read-port array may need
##                                           registered outputs or duplication
##                  Guessing which one it is cost three pipelining rounds in
##                  Phase 1. Read the report.
## =============================================================================
