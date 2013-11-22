
// Copyright (c) 2013 Nokia, Inc.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Vector::*;
import Clocks::*;
import FIFO::*;
import FIFOF::*;
import GetPut::*;

import YUV::*;
import NrccSyncBRAM::*;

interface HDMI;
    method Bit#(1) hdmi_vsync;
    method Bit#(1) hdmi_hsync;
    method Bit#(1) hdmi_de;
    method Bit#(16) hdmi_data;
    interface Clock hdmi_clock_if;
    interface Reset hdmi_reset_if;
endinterface

interface HdmiOut;
    interface Put#(Rgb888VideoData) rgb;
    interface HDMI hdmi;
endinterface

interface HdmiGenerator;
    method Action setTestPattern(Bool v);
    method Action setPatternColor(Bit#(32) v);
    method Action setHsyncWidth(Bit#(12) hsyncWidth);
    method Action setDePixelCountMinMax(Bit#(12) min, Bit#(12) max);
    method Action setVsyncWidth(Bit#(11) vsyncWidth);
    method Action setDeLineCountMinMax(Bit#(11) min, Bit#(11) max);
    method Action setNumberOfLines(Bit#(11) lines);
    method Action setNumberOfPixels(Bit#(12) pixels);
    interface HDMI hdmi;
endinterface

typedef struct {
    Bit#(11) line;
    Bit#(12) pixel;
} LinePixelCount;

typedef struct {
    Bit#(1) vsync;
    Bit#(1) hsync;
    Bool de;
    Rgb888 pixel;
    Bit#(12) dataCount;
} Rgb888Stage deriving (Bits);

typedef struct {
    Bit#(1) vsync;
    Bit#(1) hsync;
    Bool de;
    Yuv444Intermediates data;
} Yuv444IntermediatesStage deriving (Bits);

typedef struct {
    Bit#(1) vsync;
    Bit#(1) hsync;
    Bool de;
    Yuv444 data;
} Yuv444Stage deriving (Bits);

typedef struct {
    Bit#(1) vsync;
    Bit#(1) hsync;
    Bool de;
    Bit#(16) data;
} Yuv422Stage deriving (Bits);

module mkHdmiGenerator#(Clock axi_clock, Reset axi_reset,
                                   BRAM#(Bit#(12), Bit#(32)) lineBuffer,
                                   SyncPulseIfc vsyncPulse,
                                   SyncPulseIfc hsyncPulse)(HdmiGenerator);
    Clock defaultClock <- exposeCurrentClock();
    Reset defaultReset <- exposeCurrentReset();
    // 1920 * 1080
    Reg#(Bit#(12)) hsyncWidth <- mkSyncReg(44, axi_clock, axi_reset, defaultClock);
    Reg#(Bit#(12)) dePixelCountMinimum <- mkSyncReg(192, axi_clock, axi_reset, defaultClock);
    Reg#(Bit#(12)) dePixelCountMaximum <- mkSyncReg(2112, axi_clock, axi_reset, defaultClock);
    Reg#(Bit#(12)) pixelMidpoint <- mkSyncReg(1152, axi_clock, axi_reset, defaultClock);
    Reg#(Bit#(11)) vsyncWidth <- mkSyncReg(5, axi_clock, axi_reset, defaultClock);
    Reg#(Bit#(11)) deLineCountMinimum <- mkSyncReg(41, axi_clock, axi_reset, defaultClock);
    Reg#(Bit#(11)) deLineCountMaximum <- mkSyncReg(1121, axi_clock, axi_reset, defaultClock);
    Reg#(Bit#(11)) lineMidpoint <- mkSyncReg(581, axi_clock, axi_reset, defaultClock);

    Reg#(Bit#(11)) numberOfLines <- mkSyncReg(1125, axi_clock, axi_reset, defaultClock);
    Reg#(Bit#(12)) numberOfPixels <- mkSyncReg(2200, axi_clock, axi_reset, defaultClock);

    Reg#(Bit#(11)) lineCount <- mkReg(0);
    Reg#(Bit#(12)) pixelCount <- mkReg(0);

    FIFOF#(Rgb888Stage) bramOutStageFifo <- mkSizedFIFOF(8);

    Reg#(Bit#(12)) dataCount <- mkReg(0);
    Reg#(Bit#(32)) patternReg0 <- mkSyncReg(32'h00FFFFFF, axi_clock, axi_reset, defaultClock); // white

    Vector#(4, Reg#(Bit#(32))) patternRegs <- replicateM(mkReg(0));

    Reg#(Bool) shadowTestPatternEnabled <- mkSyncReg(True, axi_clock, axi_reset, defaultClock);
    Reg#(Bool) testPatternEnabled <- mkReg(True);

    let vsync = (lineCount < vsyncWidth) ? 1 : 0;
    let hsync = (pixelCount < hsyncWidth) ? 1 : 0;

    let isActiveLine = (lineCount >= deLineCountMinimum && lineCount < deLineCountMaximum);
    let dataEnable = (pixelCount >= dePixelCountMinimum && pixelCount < dePixelCountMaximum
                      && lineCount >= deLineCountMinimum && lineCount < deLineCountMaximum);

    function LinePixelCount newCounts(Bit#(11) lc, Bit#(12) pc);
        let newLineCount = lc;
        let newPixelCount = pc;
        if (pc == numberOfPixels-1)
        begin
           newPixelCount = 0; 
           if (lc == numberOfLines-1)
           begin
               newLineCount = 0;
           end
           else
               newLineCount = lc+1;
        end
        else
        begin
            newPixelCount = pc + 1;
        end
        return LinePixelCount { line: newLineCount, pixel: newPixelCount };
    endfunction

    // vsyncPulse is a SyncHandshake to a slow clock domain
    // so it is not ready every cycle.
    // Therefore, we send to it from a different rule so it does not block the fbRule
    rule sendVsyncPulse (lineCount == 0 && pixelCount == 0);
        $display("vsync pulse sent");
        vsyncPulse.send();
    endrule

    rule sendHsyncPulse (isActiveLine && pixelCount == 0);
        //$display("hsync pulse sent");
        hsyncPulse.send();
    endrule

    rule data if (testPatternEnabled);
        LinePixelCount counts = newCounts(lineCount, pixelCount);
        lineCount <= counts.line;
        pixelCount <= counts.pixel;

        //if (pixelCount == 0) $display("tpg line %d", lineCount);

        if (lineCount == 0 && pixelCount == 0)
        begin
            $display("testPatternEnabled %d", shadowTestPatternEnabled);
            testPatternEnabled <= shadowTestPatternEnabled;

            patternRegs[0] <= patternReg0; 
            patternRegs[1] <= 32'h00FF0000; // blue
            patternRegs[2] <= 32'h0000FF00; // green
            patternRegs[3] <= 32'h000000FF; // red
            //patternRegs[1] <= 32'h80ff80ff; // yuv422 white
            //patternRegs[2] <= 32'h2c961596; // yuv422 green
            //patternRegs[3] <= 32'hff1d6b1d; // yuv422 red
        end

        Bit#(2) index = 0;
        if (pixelCount >= pixelMidpoint)
            index[0] = 1;
        if (lineCount >= lineMidpoint)
            index[1] = 1;
        Bit#(32) data = patternRegs[index];

        bramOutStageFifo.enq(Rgb888Stage { vsync: vsync, hsync: hsync, de: dataEnable, pixel: unpack(truncate(data)), dataCount: 0 });
        lineBuffer.readAddr(0);

        if (dataEnable)
            dataCount <= dataCount + 1;
        else if (hsync == 1)
            dataCount <= 0;

    endrule

    rule fbRule if (!testPatternEnabled);
        LinePixelCount counts = newCounts(lineCount, pixelCount);
        lineCount <= counts.line;
        pixelCount <= counts.pixel;

        //if (pixelCount == 0) $display("fb line %d", lineCount);

        if (lineCount == 0 && pixelCount == 0)
        begin
            $display("testPatternEnabled %d", shadowTestPatternEnabled);
            testPatternEnabled <= shadowTestPatternEnabled;
        end

        if (hsync == 1)
            dataCount <= 0;
        else if (dataEnable)
            dataCount <= dataCount + 1;

        bramOutStageFifo.enq(Rgb888Stage { vsync: vsync, hsync: hsync, de: dataEnable, pixel: Rgb888{r:0,g:0,b:0}, dataCount: dataCount });
        lineBuffer.readAddr(dataCount);

    endrule

    Reg#(Rgb888Stage) rgb888StageReg <- mkReg(unpack(0));
    Reg#(Yuv444IntermediatesStage) yuv444IntermediatesStageReg <- mkReg(
        Yuv444IntermediatesStage { vsync: 0, hsync: 0, de: False, data: unpack(0) });
    Reg#(Yuv444Stage) yuv444StageReg <- mkReg(
        Yuv444Stage { vsync: 0, hsync: 0, de: False, data: unpack(0) });
    Reg#(Yuv422Stage) yuv422StageReg <- mkReg(
        Yuv422Stage { vsync: 0, hsync: 0, de: False, data: unpack(0) });
    Reg#(Bool) evenOddPixelReg <- mkReg(False);

    rule bramOutStage;
        let d <- lineBuffer.readData;
        let stageData = bramOutStageFifo.first;
        bramOutStageFifo.deq;

        if (!testPatternEnabled)
        begin
            let pixel = stageData.pixel;
            //let pixelSelect = 0; //stageData.dataCount[0];
            //if (pixelSelect == 0)
                pixel = unpack(d[23:0]);
            //else
                //pixel = unpack(d[55:32]);
            stageData.pixel = pixel;
        end
        rgb888StageReg <= stageData;
    endrule

    rule yuv444IntermediatesStage;
        let previous = rgb888StageReg;
        let pixel = previous.pixel;
        yuv444IntermediatesStageReg <= Yuv444IntermediatesStage {
            vsync: previous.vsync,
            hsync: previous.hsync,
            de: previous.de,
            data: (previous.de) ? rgbToYuvIntermediates(pixel) : unpack(0)
        };
    endrule

    rule yuv444Stage;
        let previous = yuv444IntermediatesStageReg;
        yuv444StageReg <= Yuv444Stage {
            vsync: previous.vsync,
            hsync: previous.hsync,
            de: previous.de,
            data: (previous.de) ? yuvIntermediatesToYuv444(previous.data) : unpack(0)
        };
    endrule

    rule yuv422stage;
        let previous = yuv444StageReg;
        if (previous.de)
            evenOddPixelReg <= !evenOddPixelReg;
        Bit#(16) data = { evenOddPixelReg ? previous.data.u : previous.data.v,
                          previous.data.y };
        yuv422StageReg <= Yuv422Stage {
            vsync: previous.vsync,
            hsync: previous.hsync,
            de: previous.de,
            data: data
        };
    endrule

    interface HDMI hdmi;
        method Bit#(1) hdmi_vsync;
            return yuv422StageReg.vsync;
        endmethod
        method Bit#(1) hdmi_hsync;
            return yuv422StageReg.hsync;
        endmethod
        method Bit#(1) hdmi_de;
            return yuv422StageReg.de ? 1 : 0;
        endmethod
        method Bit#(16) hdmi_data;
            return yuv422StageReg.data;
        endmethod
        interface hdmi_clock_if = defaultClock;
        interface hdmi_reset_if = defaultReset;
    endinterface

    method Action setPatternColor(Bit#(32) v);
        patternReg0 <= v;
    endmethod
    method Action setTestPattern(Bool v);
        shadowTestPatternEnabled <= v;
    endmethod
    method Action setHsyncWidth(Bit#(12) width);
        hsyncWidth <= width;
    endmethod
    method Action setDePixelCountMinMax(Bit#(12) min, Bit#(12) max);
        dePixelCountMinimum <= min;
        dePixelCountMaximum <= max;
        pixelMidpoint <= (min + max) / 2;
    endmethod
    method Action setVsyncWidth(Bit#(11) width);
        vsyncWidth <= width;
    endmethod
    method Action setDeLineCountMinMax(Bit#(11) min, Bit#(11) max);
        deLineCountMinimum <= min;
        deLineCountMaximum <= max;
        lineMidpoint <= (min + max) / 2;
    endmethod
    method Action setNumberOfLines(Bit#(11) lines);
        numberOfLines <= lines;
    endmethod
    method Action setNumberOfPixels(Bit#(12) pixels);
        numberOfPixels <= pixels;
    endmethod
endmodule

module mkHdmiOut(HdmiOut);
    Clock defaultClock <- exposeCurrentClock();
    Reset defaultReset <- exposeCurrentReset();
    Reg#(Rgb888Stage) rgb888StageReg <- mkReg(unpack(0));
    Reg#(Yuv444IntermediatesStage) yuv444IntermediatesStageReg <- mkReg(
        Yuv444IntermediatesStage { vsync: 0, hsync: 0, de: False, data: unpack(0) });
    Reg#(Yuv444Stage) yuv444StageReg <- mkReg(
        Yuv444Stage { vsync: 0, hsync: 0, de: False, data: unpack(0) });
    Reg#(Yuv422Stage) yuv422StageReg <- mkReg(
        Yuv422Stage { vsync: 0, hsync: 0, de: False, data: unpack(0) });
    Reg#(Bool) evenOddPixelReg <- mkReg(False);

    rule yuv444IntermediatesStage;
        let previous = rgb888StageReg;
        let pixel = previous.pixel;
        yuv444IntermediatesStageReg <= Yuv444IntermediatesStage {
            vsync: previous.vsync,
            hsync: previous.hsync,
            de: previous.de,
            data: (previous.de) ? rgbToYuvIntermediates(pixel) : unpack(0)
        };
    endrule

    rule yuv444Stage;
        let previous = yuv444IntermediatesStageReg;
        yuv444StageReg <= Yuv444Stage {
            vsync: previous.vsync,
            hsync: previous.hsync,
            de: previous.de,
            data: (previous.de) ? yuvIntermediatesToYuv444(previous.data) : unpack(0)
        };
    endrule

    rule yuv422stage;
        let previous = yuv444StageReg;
        if (previous.de)
            evenOddPixelReg <= !evenOddPixelReg;
        Bit#(16) data = { evenOddPixelReg ? previous.data.u : previous.data.v,
                          previous.data.y };
        yuv422StageReg <= Yuv422Stage {
            vsync: previous.vsync,
            hsync: previous.hsync,
            de: previous.de,
            data: data
        };
    endrule

    interface Put rgb;
        method Action put(Rgb888VideoData videoData);
            rgb888StageReg <= Rgb888Stage {
                vsync: videoData.vsync,
                hsync: videoData.hsync,
                de: videoData.active_video == 1 ? True : False,
                pixel: Rgb888 { r: videoData.r, g: videoData.g, b: videoData.b },
		dataCount: 0
            };
        endmethod
    endinterface
    interface HDMI hdmi;
        method Bit#(1) hdmi_vsync;
            return yuv422StageReg.vsync;
        endmethod
        method Bit#(1) hdmi_hsync;
            return yuv422StageReg.hsync;
        endmethod
        method Bit#(1) hdmi_de;
            return yuv422StageReg.de ? 1 : 0;
        endmethod
        method Bit#(16) hdmi_data;
            return yuv422StageReg.data;
        endmethod
        interface hdmi_clock_if = defaultClock;
        interface hdmi_reset_if = defaultReset;
    endinterface
endmodule
