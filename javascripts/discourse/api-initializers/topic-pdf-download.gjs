import { apiInitializer } from "discourse/lib/api";
import TopicPdfButton from "../components/topic-pdf-button";

export default apiInitializer((api) => {
  // Primary: right sidebar. When a table of contents is present it
  // takes over this panel and pushes the button below the fold.
  api.renderInOutlet(
    "topic-navigation",
    <template>
      <TopicPdfButton @outletArgs={{@outletArgs}} />
    </template>
  );

  // Secondary: always visible at the bottom of the post stream,
  // below the last post and above the footer action buttons.
  // This ensures the button is accessible even on long TOC topics.
  api.renderInOutlet(
    "above-topic-footer-buttons",
    <template>
      <TopicPdfButton @outletArgs={{@outletArgs}} />
    </template>
  );
});
