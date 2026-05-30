import Image from "next/image";
import { Board } from "@/features/board/components/board";
import { LiveStatus } from "@/features/board/components/live-status";

export default function Home() {
  return (
    <main className="flex h-screen flex-col bg-background">
      <header className="flex items-center gap-3 border-b px-4 py-3">
        <h1 className="m-0 flex items-center gap-1.5 font-normal leading-none">
          <span
            className="text-[18px] italic leading-none text-foreground"
            style={{ fontFamily: "var(--font-lora), serif" }}
          >
            Symphony
          </span>
          <span className="select-none text-[10px] text-muted-foreground">by</span>
          <Image
            src="/moonshot.png"
            alt="Moonshot"
            width={71}
            height={14}
            priority
            className="opacity-80"
          />
        </h1>
        <span className="hidden border-l pl-3 text-xs text-muted-foreground sm:inline">
          Cockpit
        </span>
        <div className="ml-auto">
          <LiveStatus />
        </div>
      </header>
      <div className="min-h-0 flex-1">
        <Board />
      </div>
    </main>
  );
}
