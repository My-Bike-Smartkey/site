import struct
import binascii

payloads = [
    "3c0e9e4507000000e002e3bc00000050559942430000e841000000000000000000000000004166f442",
    "3c0e9e4507000000e00263bd000001ff529942430000e841000000000000000002000000000866f442"
]

for idx, p in enumerate(payloads):
    data = binascii.unhexlify(p)
    print(f"-- Payload {idx} --")
    print(f"Odo (float 0): {struct.unpack('<f', data[0:4])[0]}")
    print(f"Motor (float 20): {struct.unpack('<f', data[20:24])[0]}")
    print(f"ECU (float 24): {struct.unpack('<f', data[24:28])[0]}")
