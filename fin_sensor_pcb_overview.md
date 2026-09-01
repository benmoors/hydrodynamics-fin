# Surfboard Fin Sensor PCB — System and Component Reference

## Purpose of this document

This document explains the function of a custom printed circuit board (PCB) being designed for a surfboard fin sensor, and the role of each component on it. It is written as a self-contained reference: it includes the project context, the overall system architecture, a component-by-component explanation, PCB-level design considerations, the design decisions that are still open, and a glossary of terms. Where a component choice has not been finalised, the leading candidate is described and the decision is explicitly flagged as open.

## Project context

The device is a sensor module embedded in (or attached to) a surfboard fin. Its purpose is to measure how the board moves through the water during a surf session: turn rate (how quickly the surfer is rotating the board), board orientation, board speed, and depth/pressure information that can be related to wave performance. The device records data locally during the session and the data is extracted afterwards for analysis on a computer.

The operating environment drives most of the design. The board is immersed in saltwater, which is electrically conductive and highly corrosive, so the electronics must be sealed to roughly IP68 standard (protected against continuous immersion). At the same time, the pressure sensor must be in direct contact with the water to do its job, and the battery must be rechargeable without opening the enclosure. These conflicting requirements shape the component selection: a media-isolated pressure sensor whose sensing port can safely face the water, inductive (wireless) charging so no charging connector penetrates the enclosure, and a data-extraction method that either works wirelessly (Bluetooth Low Energy) or through sealed spring-loaded contacts (magnetic pogo pins). Radio signals are strongly attenuated by water, so no live data streaming happens while surfing; the device logs to onboard memory and offloads after the session.

The developer is prototyping the sensors on an Arduino first, then designing the final PCB in Altium Designer around an STM32 microcontroller.

## System architecture overview

The system has two chains: a **signal/data chain** and a **power chain**.

**Signal/data chain.** The inertial measurement unit (IMU) continuously measures acceleration, angular rate, and magnetic field. The pressure sensor measures absolute water pressure and temperature. Both sensors are digital: they contain their own analogue front-ends and analogue-to-digital converters, and present finished digital readings over standard serial buses (SPI for the IMU, I2C for the pressure sensor). The STM32 microcontroller polls or receives these readings at a fixed sample rate, timestamps them, optionally runs sensor-fusion mathematics to estimate orientation, and writes the data stream to an external SPI NOR flash memory chip. After the session, the logged data is transferred off the device — either over Bluetooth Low Energy (if the chosen microcontroller variant includes a radio) or over a wired serial link exposed through magnetic pogo-pin contacts. The same pogo-pin pads can expose the SWD programming/debug interface used to flash firmware onto the microcontroller.

**Power chain.** Energy enters the sealed enclosure magnetically: an external transmitter coil couples to a receiver coil inside the enclosure. A wireless power receiver IC converts the coil's AC into a regulated DC supply, which feeds a lithium battery charger IC. The charger manages the charging of a single lithium-polymer cell. During operation, the cell's voltage (nominally 3.7 V, ranging roughly 3.0–4.2 V) is regulated down to a stable 3.3 V rail that powers the microcontroller, sensors, and memory.

## Components and their functions

### ICM-20948 — 9-axis inertial measurement unit (IMU)

The ICM-20948 (TDK InvenSense) is the primary motion sensor. It combines three sensors in one package: a 3-axis accelerometer (measures linear acceleration, selectable range ±2/±4/±8/±16 g), a 3-axis gyroscope (measures angular rate, selectable range ±250/±500/±1000/±2000 degrees per second), and a 3-axis magnetometer (an embedded AK09916 die that measures the local magnetic field, intended for compass heading). It also contains a Digital Motion Processor (DMP), an on-chip coprocessor that can compute fused orientation outputs internally.

On this PCB, the ICM-20948 provides the raw data for turn rate (directly from the gyroscope), board orientation (from fusing accelerometer and gyroscope data), and motion dynamics. It connects to the microcontroller over SPI (it supports both SPI and I2C; SPI is preferred here for speed and because it leaves the I2C bus free for the pressure sensor). Its SPI interface operates in SPI mode 0 or mode 3, which must be matched in the microcontroller's SPI peripheral configuration. The chip runs from the 3.3 V rail (it accepts a supply from roughly 1.7 to 3.6 V) and includes an internal FIFO buffer that accumulates samples so the microcontroller can read them in efficient bursts rather than one at a time.

Two practical caveats are part of the design assumptions. First, the DMP is poorly documented and difficult to use, so the design plans to read raw accelerometer/gyroscope data and perform sensor fusion in the microcontroller instead. Second, the magnetometer is expected to be unreliable in this installation: it sits close to the battery, copper traces, and possibly steel hardware, all of which distort the magnetic field. Absolute compass heading is therefore not a design requirement; orientation is estimated from the accelerometer and gyroscope only.

PCB considerations for this part: it is a small QFN-style leadless package with a thermal/ground pad underneath, which requires reflow soldering and a correctly drawn footprint; decoupling capacitors must be placed immediately at its supply pins; and it should be mounted with a known, rigid orientation relative to the fin so its sensing axes map cleanly onto the board's axes.

### MS5837-30BA — media-isolated pressure and temperature sensor (leading candidate; selection open)

The MS5837-30BA (TE Connectivity) is the leading candidate for the water pressure sensor. It is a piezoresistive MEMS pressure sensor with a 24-bit analogue-to-digital converter, measuring absolute pressure from 0 to 30 bar, which corresponds to water depths well beyond anything encountered while surfing. Critically, it is *media-isolated*: the sensing element sits behind a gel-filled port designed to face liquid directly. This resolves the central sealing conflict — the gel port is exposed to the saltwater while the rest of the PCB remains fully encapsulated. The same class of part is used in underwater robotics (it is the sensor inside the Blue Robotics Bar30 depth sensor). It also reports temperature, which is used internally for pressure compensation and is available as a data channel.

Functionally, the sensor serves two purposes. Its dominant reading is hydrostatic pressure — pressure due to depth below the surface (pressure increases by about 0.1 bar per metre of water) — which indicates how deep the fin is, e.g. duck-diving versus riding. The second, much smaller, component of its reading is dynamic pressure, which depends on the speed of water flow past the sensor (dynamic pressure equals one half times water density times velocity squared, from Bernoulli's principle). In principle this allows speed estimation; in practice, separating the small dynamic component from the large hydrostatic component in choppy surf conditions is a difficult signal-processing problem and is flagged as an open analysis question, not a solved feature.

The sensor communicates over I2C only, runs from the 3.3 V rail, and requires a mechanical design in which its port passes through the enclosure wall with a watertight seal (typically an O-ring around the sensor body).

An important note recorded for context: an earlier sourcing idea, tactile pressure-indicating film from Sensor Products Inc (sensorprod.com), was ruled out. That product is a colour-changing film for mapping contact pressure between two solid surfaces; it is not an electronic transducer and cannot measure water pressure in real time.

### STM32 microcontroller (family chosen; exact part open — STM32L4 vs STM32WB55)

The microcontroller (MCU) is the computer at the centre of the board. Its jobs are: configure and read both sensors at a fixed sample rate; timestamp the data; run sensor-fusion filter mathematics (e.g., a complementary or Madgwick filter) to estimate orientation; write the data stream to the external flash memory; manage power (sleeping between samples to extend battery life); and handle data offload after the session.

The design is committed to the STM32 family (STMicroelectronics, ARM Cortex-M cores) with a hard requirement for a **Cortex-M4F core**, meaning a core with a hardware floating-point unit (FPU). Sensor-fusion algorithms run in floating-point arithmetic, and cores without an FPU (Cortex-M0/M0+) execute floating-point operations in slow software emulation. Two candidates remain, and the choice is tied directly to the open data-extraction decision:

**STM32L4 series** — a low-power Cortex-M4F microcontroller with no radio. Simpler and cheaper. Choosing it implies data extraction over wired magnetic pogo-pin contacts, since adding a separate Bluetooth chip and antenna would be significant extra design work.

**STM32WB55** — a dual-core device containing a Cortex-M4F application core plus a Cortex-M0+ core dedicated to an integrated Bluetooth Low Energy (BLE) 5.x radio. Choosing it provides wireless data offload with no connector penetrating the enclosure, at the cost of antenna design and an RF keep-out region on the PCB.

Either way, the MCU is programmed and debugged over SWD (Serial Wire Debug), a two-signal ARM interface (SWDIO and SWCLK, plus reset, ground, and power reference). Because the finished board is sealed, the SWD signals are routed to gold-plated pads intended for a spring-loaded (pogo-pin) programming jig, so firmware can be flashed before final sealing and, if the pads remain accessible, afterwards as well. The firmware toolchain is STM32CubeMX (graphical pin/clock/peripheral configuration and HAL code generation) with STM32CubeIDE.

### W25Q-series SPI NOR flash — data logging memory

The Winbond W25Q family is a line of serial NOR flash memory chips accessed over SPI. One of these chips is the device's session data logger: the MCU appends sensor records to it throughout a surf session, and the full log is read back out during offload. NOR flash is non-volatile (data survives power loss), and a soldered-down chip in a small package has no moving parts, no card socket, and no opening in the enclosure — which is why it was chosen over a microSD card, whose socket would be both a hole in the waterproofing and a saltwater corrosion trap.

Working characteristics that shape the firmware: NOR flash is written in pages (typically 256 bytes) and must be erased in larger blocks (typically 4 KB sectors) before rewriting — you cannot overwrite in place — so the logging firmware writes sequentially and manages erasure explicitly. Capacity is chosen from the family (common sizes range from 16 Mbit to 256 Mbit) based on sample rate, record size, and session length. The chip shares the SPI bus wiring style with the IMU but is selected with its own chip-select line, or placed on a second SPI peripheral.

### Wireless power receiver IC and receiver coil — inductive charging input

The receiver coil is a flat spiral of wire inside the enclosure. When placed on a charging transmitter, an alternating magnetic field induces an AC voltage in this coil; the wireless power receiver IC rectifies and regulates that AC into a clean DC output used to charge the battery. A representative part is the Texas Instruments BQ51013B, a Qi-compatible 5 W receiver, if the design follows the Qi standard (which allows charging from off-the-shelf Qi pads, including phone chargers). The alternative — a simpler proprietary coil pair with a matching custom transmitter — remains an open decision.

This subsystem imposes two hard physical constraints recorded elsewhere in this document: a copper keep-out zone on the PCB beneath the coil (any copper plane under the coil absorbs the field as eddy currents, killing efficiency and generating heat), and a limit on enclosure wall thickness between the two coils, since coupling efficiency falls rapidly with distance.

### Lithium battery charger IC — battery management

Between the wireless receiver and the battery sits a dedicated single-cell lithium charger IC, for example the Texas Instruments BQ2407x family. Lithium-polymer cells must be charged with a precise constant-current/constant-voltage profile terminating at 4.2 V; overcharging is a safety hazard and undercharging shortens life. The charger IC implements this profile, monitors temperature, and (in power-path variants) can power the system while simultaneously charging the battery. Its inputs are the DC from the wireless receiver; its output is the battery terminal.

### Lithium-polymer battery cell

A single lithium-polymer (LiPo) pouch cell stores the device's energy: nominal 3.7 V, charged to 4.2 V, discharged down to roughly 3.0 V. Capacity is an open sizing decision driven by session length, sample rate, and sleep current. Two safety constraints are recorded as design rules: the cell must include (or be paired with) a protection circuit against over-discharge and short circuit, and the cell must **not** be rigidly potted in epoxy — lithium pouch cells need mechanical room to expand and a path to shed heat, so the sealing strategy must leave the battery in a compliant mounting even inside a sealed enclosure.

### 3.3 V voltage regulator

The battery voltage varies from about 4.2 V down to 3.0 V as it discharges, but the MCU, sensors, and flash all want a stable 3.3 V (or slightly lower) supply. A regulator provides this rail. The choice between a low-dropout linear regulator (LDO — simple, electrically quiet, but dissipates the voltage difference as heat) and a small buck (switching) converter (more efficient, slightly noisier and more complex) is a minor open decision; for the low currents involved, a low-quiescent-current LDO is the likely choice, because the regulator's own idle consumption directly limits standby battery life.

### Supporting components

**Decoupling/bypass capacitors** — small ceramic capacitors (typically 100 nF plus some bulk capacitance) placed immediately at every IC's power pins. They supply the fast transient currents digital chips draw and keep the supply rails quiet. Their electrical value matters less than their placement: a decoupling capacitor placed far from the pin it serves is nearly useless.

**I2C pull-up resistors** — the I2C bus is open-drain, meaning devices can only pull the lines low; two resistors (typically 2.2–10 kΩ) to the 3.3 V rail pull the SDA and SCL lines high. Without them the bus does not function.

**Crystal(s)** — a 32.768 kHz watch crystal gives the MCU an accurate low-power clock for timestamping and sleep timing; depending on the MCU variant and whether BLE is used, a high-speed crystal (e.g., 32 MHz for the STM32WB55 radio) is also required and has tight layout requirements.

**BLE antenna (only if the STM32WB55 path is chosen)** — either a PCB trace antenna or a small chip antenna, with a ground-free keep-out area around it and a matching network of small inductors/capacitors between it and the radio pin.

**Magnetic pogo-pin pads (only if the wired path is chosen; SWD pads present in either case)** — gold-plated (ENIG) exposed pads on the board edge or enclosure face that mate with spring-loaded pins in an external dock, carrying SWD for programming and, in the wired-offload design, a UART or USB serial link for data extraction. Exposed metal in saltwater is a known corrosion and maintenance point.

**Optional NFC tag IC (ST25DV, under consideration)** — an ST "dynamic NFC tag" that connects to the MCU over I2C and exposes a small memory readable by a phone held against the enclosure. Its bandwidth is far too low to offload full sensor logs; if included, its role is limited to configuration and status (e.g., battery level, session count) through the sealed wall.

## PCB-level design considerations

These board-wide rules apply regardless of final component choices. The board uses a solid, unbroken ground plane, because every high-frequency signal's return current flows in the copper directly beneath its trace, and splits or slots under signals cause noise and EMI. Decoupling capacitors sit at the pins they serve. The wireless-charging coil area and (if applicable) the antenna area are copper keep-out zones. The surface finish is ENIG (electroless nickel immersion gold) for corrosion resistance in the salt environment and for durable gold contact pads. Connectors are designed out wherever possible — every connector is a leak path and corrosion site. There are no differential pairs on this board: SPI and I2C are single-ended buses, and the only interface that would introduce a differential pair (USB) is deliberately avoided because a USB connector conflicts with sealing. The board outline is shaped to the fin cavity, and design rules (minimum trace width/spacing, drill sizes, annular ring) are loaded from the chosen fabrication house before routing begins.

## Open design decisions (as of August 2026)

1. **Data extraction method** — BLE (implies STM32WB55) versus magnetic pogo-pin wired link (allows STM32L4); NFC considered only as a supplementary config/status channel. This is the pivotal open decision; the MCU part number, antenna work, and contact-pad design all follow from it.
2. **Exact pressure sensor part** — MS5837-30BA is the leading candidate; equivalent TE/Amphenol media-isolated transducers are alternatives.
3. **Inductive charging standard** — Qi (off-the-shelf transmitters) versus a simpler proprietary coil pair.
4. **Battery capacity**, **flash capacity**, and **regulator type (LDO vs buck)** — sizing decisions pending power and data-rate budgets.
5. **Sealing method** — full potting versus conformal coating inside a sealed O-ring enclosure (with the battery and pressure port excluded from potting in any case).
6. **Speed estimation source** — pressure-derived dynamic pressure, GPS, or fusion; an analysis-side question rather than a board-side one, but it may influence whether a GPS receiver is ever added.

## Glossary

**ADC (analogue-to-digital converter)** — circuit that converts a continuous voltage into a digital number. **BLE (Bluetooth Low Energy)** — short-range, low-power radio protocol used for data offload. **CPOL/CPHA** — SPI clock polarity and phase settings; together they define SPI modes 0–3, which must match between MCU and peripheral. **Decoupling capacitor** — capacitor at an IC's power pin supplying fast transient current. **DMP (Digital Motion Processor)** — the ICM-20948's on-chip fusion coprocessor. **DRC (design rule check)** — automated check in the PCB tool against manufacturing rules. **ENIG** — electroless nickel immersion gold, a corrosion-resistant PCB surface finish. **FIFO** — first-in-first-out hardware buffer that accumulates sensor samples. **FPU (floating-point unit)** — hardware for fast floating-point arithmetic; present on Cortex-M4F. **Hydrostatic pressure** — pressure due to depth of water above the sensor. **Dynamic pressure** — pressure component due to flow speed (½ρv²). **I2C** — two-wire serial bus (SDA data, SCL clock) with open-drain lines and pull-up resistors; used by the pressure sensor. **IMU (inertial measurement unit)** — combined accelerometer/gyroscope (and here, magnetometer) sensor. **IP68** — ingress protection rating: dust-tight and protected against continuous immersion. **LDO (low-dropout regulator)** — simple linear voltage regulator. **Media-isolated** — a pressure sensor whose sensing element is protected (here by gel) so the port can directly face liquid. **MEMS** — micro-electro-mechanical systems; the fabrication technology of the IMU and pressure sensor. **NOR flash** — non-volatile memory type used for logging; written in pages, erased in sectors. **Pogo pins** — spring-loaded contact pins pressed against gold pads to make a temporary electrical connection. **Potting** — encapsulating electronics in solid epoxy or urethane. **Qi** — the common wireless (inductive) charging standard. **Sensor fusion** — combining accelerometer and gyroscope data mathematically to estimate orientation (e.g., complementary, Madgwick, or Kalman filters). **SPI** — four-wire serial bus (SCLK clock, MOSI/MISO data, CS chip-select), full-duplex, single-ended; used by the IMU and flash. **SWD (Serial Wire Debug)** — ARM's two-wire programming/debug interface. **QFN** — quad flat no-lead package; a small leadless IC package soldered by reflow.
