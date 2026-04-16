import React, { useState, useEffect } from 'react';
import {
    Settings, Signal, Battery, Shield, Power, Zap,
    Volume2, RefreshCw, Lock, Unlock, Hash, Activity, Bluetooth
} from 'lucide-react';

// Thành phần Logo V-Hexa (Được tái sử dụng làm nút trung tâm)
const VHexaLogo = ({ className, glowing }) => (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className={className}>
        {/* Khối lục giác bên ngoài */}
        <path
            d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"
            className={glowing ? "drop-shadow-[0_0_8px_rgba(255,255,255,0.5)]" : ""}
        />
        {/* Chữ V và rãnh chìa khóa bên trong */}
        <path d="M8 10l4 4 4-4" />
        <path d="M12 14v5" />
        <path d="M12 5v2" />
    </svg>
);

export default function App() {
    const [isLocked, setIsLocked] = useState(true);
    const [isRefreshing, setIsRefreshing] = useState(false);

    const handleRefresh = () => {
        setIsRefreshing(true);
        setTimeout(() => setIsRefreshing(false), 1000);
    };

    // Màu sắc chủ đạo linh hoạt theo trạng thái
    const accentColor = isLocked ? 'rgb(239, 68, 68)' : 'rgb(0, 229, 255)'; // Red vs Cyan
    const accentGlow = isLocked ? 'rgba(239, 68, 68, 0.5)' : 'rgba(0, 229, 255, 0.5)';

    return (
        <div className="min-h-screen bg-[#050505] flex items-center justify-center font-sans p-4 sm:p-8">

            {/* Phone Mockup Frame */}
            <div className="w-full max-w-[400px] h-[850px] max-h-full bg-black sm:rounded-[3rem] sm:border-[8px] border-neutral-800 shadow-[0_0_100px_rgba(0,0,0,1)] relative overflow-hidden flex flex-col font-sans">

                {/* Background Mesh/Gradient Effect */}
                <div className="absolute inset-0 pointer-events-none overflow-hidden">
                    {/* Lưới Grid tinh tế chìm dưới nền */}
                    <div className="absolute inset-0 bg-[linear-gradient(to_right,#ffffff05_1px,transparent_1px),linear-gradient(to_bottom,#ffffff05_1px,transparent_1px)] bg-[size:24px_24px]"></div>
                    {/* Ánh sáng hắt từ trên xuống */}
                    <div
                        className="absolute -top-32 left-1/2 -translate-x-1/2 w-[150%] h-[500px] rounded-full blur-[120px] opacity-20 transition-all duration-1000"
                        style={{ backgroundColor: accentColor }}
                    ></div>
                </div>

                {/* --- HEADER --- */}
                <div className="relative z-20 px-6 pt-14 pb-2 flex justify-between items-center">
                    <div>
                        <p className="text-neutral-500 text-xs font-bold uppercase tracking-wider mb-1">D-Smartkey</p>
                        <div className="flex flex-col gap-1.5">
                            <h1 className="text-2xl font-bold tracking-tight text-white flex items-center gap-2">
                                Ngựa sắt
                            </h1>
                            <div className="flex items-center gap-2">
                                {/* Trạng thái kết nối chung */}
                                <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-white/10 border border-white/5 backdrop-blur-md">
                                    <span className="w-1.5 h-1.5 rounded-full bg-green-500 animate-pulse"></span>
                                    <span className="text-[10px] font-medium text-neutral-300">Đã kết nối</span>
                                </div>
                                {/* Tín hiệu cường độ BLE */}
                                <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-blue-500/10 border border-blue-500/20 backdrop-blur-md" title="Cường độ Bluetooth">
                                    <Bluetooth size={10} className="text-blue-400" />
                                    <div className="flex gap-[2px] items-end h-2.5">
                                        <div className="w-[3px] h-1 bg-blue-400 rounded-sm"></div>
                                        <div className="w-[3px] h-1.5 bg-blue-400 rounded-sm"></div>
                                        <div className="w-[3px] h-2 bg-blue-400 rounded-sm"></div>
                                        <div className="w-[3px] h-2.5 bg-neutral-600 rounded-sm"></div>
                                    </div>
                                    <span className="text-[10px] font-mono text-blue-400 ml-0.5">-68 dBm</span>
                                </div>
                            </div>
                        </div>
                    </div>
                    <button className="w-10 h-10 flex items-center justify-center rounded-full bg-white/[0.05] border border-white/[0.05] backdrop-blur-xl hover:bg-white/10 transition-colors">
                        <Settings size={18} className="text-neutral-300" />
                    </button>
                </div>

                {/* --- MAIN CENTER ACTION (Bento Style) --- */}
                <div className="relative z-10 flex-1 flex flex-col items-center justify-center mt-2">

                    <div className="relative w-[300px] h-[300px] flex items-center justify-center">
                        {/* Vòng tròn Radar cực mỏng */}
                        <div
                            className={`absolute inset-0 rounded-full border-[1px] border-dashed opacity-30 transition-all duration-1000
              ${isLocked ? 'animate-[spin_40s_linear_infinite]' : 'animate-[spin_20s_linear_infinite_reverse] scale-110'}`}
                            style={{ borderColor: accentColor }}
                        ></div>
                        <div className="absolute inset-8 rounded-full border-[1px] border-white/5 bg-white/[0.01] backdrop-blur-3xl"></div>

                        {/* Nút trung tâm */}
                        <button
                            onClick={() => setIsLocked(!isLocked)}
                            className="relative z-20 w-36 h-36 rounded-full flex items-center justify-center transition-all duration-500 group"
                            style={{
                                background: `radial-gradient(circle at center, ${accentGlow} 0%, transparent 70%)`,
                            }}
                        >
                            <div
                                className="absolute inset-2 rounded-full border border-white/20 backdrop-blur-md transition-transform duration-300 group-hover:scale-105 group-active:scale-95 shadow-2xl flex items-center justify-center"
                                style={{ backgroundColor: isLocked ? 'rgba(239, 68, 68, 0.1)' : 'rgba(0, 229, 255, 0.1)' }}
                            >
                                <VHexaLogo
                                    className={`w-14 h-14 transition-colors duration-500 ${isLocked ? 'text-red-500' : 'text-cyan-400'}`}
                                    glowing={true}
                                />
                            </div>
                        </button>
                    </div>

                    <p className="mt-8 text-neutral-400 text-sm font-medium tracking-wide">
                        {isLocked ? 'Chạm để MỞ KHÓA' : 'Chạm để KHÓA XE'}
                    </p>
                </div>

                {/* --- QUICK STATS WIDGET --- */}
                <div className="relative z-10 px-6 mt-4">
                    <div className="bg-white/[0.03] border border-white/5 rounded-[24px] p-5 backdrop-blur-2xl grid grid-cols-3 gap-4">
                        <div className="flex flex-col items-center justify-center gap-1 border-r border-white/5">
                            <Battery size={18} className="text-green-400 mb-1" />
                            <span className="text-xl font-semibold text-white font-mono">85%</span>
                            <span className="text-[10px] text-neutral-500 uppercase font-bold tracking-wider">Pin</span>
                        </div>
                        <div className="flex flex-col items-center justify-center gap-1 border-r border-white/5">
                            <Activity size={18} className="text-blue-400 mb-1" />
                            <span className="text-xl font-semibold text-white font-mono">62</span>
                            <span className="text-[10px] text-neutral-500 uppercase font-bold tracking-wider">KM Còn lại</span>
                        </div>
                        <div className="flex flex-col items-center justify-center gap-1">
                            <Hash size={18} className="text-neutral-400 mb-1" />
                            <span className="text-xl font-semibold text-white font-mono">4934</span>
                            <span className="text-[10px] text-neutral-500 uppercase font-bold tracking-wider">ODO</span>
                        </div>
                    </div>
                </div>

                {/* --- BENTO GRID CONTROLS --- */}
                <div className="relative z-10 px-6 pt-4 pb-10 sm:pb-12 mt-auto mb-2">
                    <div className="grid grid-cols-4 gap-3">

                        {/* Chống trộm - Ô lớn */}
                        <BentoCard
                            colSpan="col-span-2"
                            icon={Shield}
                            label="Chống trộm"
                            isActive={isLocked}
                            disabled={isLocked}
                            activeColor="bg-red-500"
                            textColor="text-red-500"
                            onClick={() => setIsLocked(true)}
                        />

                        {/* Tìm xe & Làm mới - Ô nhỏ vuông */}
                        <BentoCard
                            colSpan="col-span-1"
                            icon={Volume2}
                            label="Tìm"
                            isSquare
                            textColor="text-blue-400"
                        />
                        <BentoCard
                            colSpan="col-span-1"
                            icon={RefreshCw}
                            label="Tải lại"
                            isSquare
                            textColor="text-purple-400"
                            disabled={isRefreshing}
                            onClick={handleRefresh}
                            iconClassName={isRefreshing ? 'animate-spin' : ''}
                        />

                        {/* Bật & Tắt xe - Ô chữ nhật */}
                        <BentoCard
                            colSpan="col-span-2"
                            icon={Zap}
                            label="Bật xe"
                            subLabel="Power ON"
                            isActive={!isLocked}
                            disabled={!isLocked}
                            activeColor="bg-cyan-500"
                            textColor="text-cyan-400"
                            onClick={() => setIsLocked(false)}
                        />
                        <BentoCard
                            colSpan="col-span-2"
                            icon={Power}
                            label="Tắt xe"
                            subLabel="Power OFF"
                            disabled={isLocked}
                            textColor="text-red-400"
                            onClick={() => setIsLocked(true)}
                        />

                    </div>
                </div>

            </div>
        </div>
    );
}

// Component Bento Card mới cho các nút điều khiển
const BentoCard = ({ colSpan, icon: Icon, label, subLabel, isSquare, isActive, disabled, activeColor, textColor, onClick, iconClassName }) => {
    return (
        <button
            onClick={disabled ? undefined : onClick}
            disabled={disabled}
            className={`relative overflow-hidden flex flex-col justify-center rounded-2xl transition-all duration-300 border text-left
        ${colSpan} 
        ${isSquare ? 'aspect-square items-center p-2' : 'p-4'}
        ${disabled ? 'cursor-not-allowed' : 'active:scale-95'}
        ${disabled && !isActive ? 'opacity-30 bg-white/[0.01] border-white/[0.02] grayscale-[30%]' : ''}
        ${isActive ? `${activeColor} border-transparent shadow-[0_4px_20px_rgba(0,0,0,0.5)]` : ''}
        ${!isActive && !disabled ? 'bg-white/[0.04] border-white/5 hover:bg-white/[0.08]' : ''}
      `}
        >
            <div className={`
        ${isSquare ? 'mb-1' : 'mb-3'} 
        ${isActive ? 'text-white' : disabled ? 'text-neutral-500' : textColor}
      `}>
                <Icon size={isSquare ? 20 : 24} className={iconClassName || ''} />
            </div>

            <div className={`${isSquare ? 'text-center' : ''}`}>
                <h3 className={`font-semibold tracking-wide ${isSquare ? 'text-[11px]' : 'text-sm'} ${isActive ? 'text-white' : disabled ? 'text-neutral-500' : 'text-neutral-200'}`}>
                    {label}
                </h3>
                {subLabel && (
                    <p className={`text-[10px] font-medium mt-0.5 ${isActive ? 'text-white/80' : disabled ? 'text-neutral-600' : 'text-neutral-500'}`}>
                        {subLabel}
                    </p>
                )}
            </div>

            {/* Hiệu ứng kính mờ (Glow) góc thẻ - Ẩn khi disabled */}
            {!isActive && !disabled && (
                <div className={`absolute -bottom-6 -right-6 w-16 h-16 rounded-full blur-2xl opacity-20 ${textColor.replace('text-', 'bg-')}`}></div>
            )}
        </button>
    );
};