import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { Providers } from "./providers";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
  viewportFit: "cover",
};

const miniAppEmbed = JSON.stringify({
  version: "1",
  imageUrl: "https://app-fawn-ten-85.vercel.app/image.png",
  button: {
    title: "Open App",
    action: {
      type: "launch_miniapp",
      name: "Preconfirmations",
      url: "https://app-fawn-ten-85.vercel.app",
      splashImageUrl: "https://app-fawn-ten-85.vercel.app/splash.png",
      splashBackgroundColor: "#1e40af",
    },
  },
});

export const metadata: Metadata = {
  title: "Preconfirmation",
  description:
    "Safe pending transfers with secret-based confirmation and timeout recovery",
  other: {
    "fc:miniapp": miniAppEmbed,
    "fc:frame": miniAppEmbed,
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
