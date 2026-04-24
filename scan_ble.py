import asyncio
from bleak import BleakScanner

async def run():
    print("📡 Bắt đầu quét các thiết bị BLE xung quanh (10 giây)...")
    
    # Quét trả về dict {address: (device, adv_data)}
    devices = await BleakScanner.discover(timeout=10.0, return_adv=True)
    
    print("\n--- KẾT QUẢ QUÉT ---")
    found_esp = False
    
    for address, (device, adv_data) in devices.items():
        if device.name and "ESP-Smartkey" in device.name:
            print(f"✅ ĐÃ TÌM THẤY MẠCH ESP32!")
            print(f"   Tên thiết bị : {device.name}")
            print(f"   Địa chỉ MAC  : {address}")
            print(f"   Độ mạnh sóng : {adv_data.rssi} dBm")
            print(f"   Service UUIDs: {adv_data.service_uuids}")
            try:
                print(f"   Chi tiết     : {device.details}")
            except:
                pass
            found_esp = True
            
    if not found_esp:
        print("❌ Không tìm thấy mạch ESP-Smartkey nào đang phát sóng.")
        print("💡 Gợi ý:")
        print("   1. Hãy chắc chắn mạch đang cắm điện.")
        print("   2. Mở Serial Monitor và gõ lệnh 'prov' để bật chế độ Provisioning.")
        print("   3. Đèn LED xanh trên mạch phải nháy kép liên tục.")

if __name__ == "__main__":
    asyncio.run(run())


